# hogdot

**hogdot is a fork of the Godot Engine that adds a WebGPU rendering backend.**

It exists for one purpose: to carry [GodotWebGPU](https://github.com/dwalter/godotwebgpu)'s WebGPU
backend on top of a current mainline Godot release. Everything below this section is Godot's own
README, unmodified — hogdot is Godot, plus one renderer.

## What the fork adds

- `drivers/webgpu/` — `RenderingDeviceDriverWebGPU` and `RenderingContextDriverWebGPU`, implemented
  against `emdawnwebgpu`/Dawn. It fills the gaps between Godot's `RenderingDevice` contract and what
  WebGPU actually offers: a push-constant ring buffer (WebGPU has no push constants), subpass
  flattening (no subpasses), and split combined samplers.
- **SPIR-V → WGSL at runtime.** Godot's shaders compile to SPIR-V as usual; a preprocessing pass
  rewrites the constructs WGSL cannot express, and vendored [Tint](https://dawn.googlesource.com/dawn)
  translates the result. `thirdparty/tint/`, `thirdparty/spirv-tools/` and an expanded
  `thirdparty/spirv-headers/` come along for that.
- **Web-platform integration** — WebGPU device and adapter setup in `platform/web/`, and the
  `webgpu=yes` SCons option that turns all of it on.

## Building

```bash
# Web export template (the reason this fork exists)
scons platform=web target=template_debug webgpu=yes opengl3=no threads=no num_jobs=4

# Native editor — unchanged from mainline, and the cheap regression check
scons platform=macos target=editor arch=arm64
```

⚠ `webgpu=yes` needs `glslangValidator` on `$PATH` and an Emscripten toolchain. `num_jobs=4` is not
a suggestion on a 24 GB machine — the Tint and SPIRV-Tools sources will exhaust memory at the default
job count.

## Status and scope

The WebGPU backend targets the **Mobile** renderer and the **web** platform. Forward+-only features
(SSAO, SSIL, SSR, volumetric fog, SDFGI, TAA, FSR2, subsurface scattering) are unavailable there, as
they are on Mobile generally — that is Godot's own constraint, not a WebGPU one.

This is a long-term fork: every mainline release repeats the rebase-forward exercise, so the port
surface is derived by `./hogdot/port-surface.sh` rather than written down anywhere that could rot.

## Upstream and license

hogdot tracks [godotengine/godot](https://github.com/godotengine/godot) and is MIT-licensed, exactly
as Godot is. The WebGPU backend originates with
[dwalter/godotwebgpu](https://github.com/dwalter/godotwebgpu); its authorship is preserved in this
repository's history, and every ported commit cites the upstream commits it carries. Bugs in this
fork are the fork's own — please do not report them to the Godot project.

---

# Godot Engine

<p align="center">
  <a href="https://godotengine.org">
    <img src="misc/logo/logo_outlined.svg" width="400" alt="Godot Engine logo">
  </a>
</p>

## 2D and 3D cross-platform game engine

**[Godot Engine](https://godotengine.org) is a feature-packed, cross-platform
game engine to create 2D and 3D games from a unified interface.** It provides a
comprehensive set of [common tools](https://godotengine.org/features), so that
users can focus on making games without having to reinvent the wheel. Games can
be exported with one click to a number of platforms, including the major desktop
platforms (Linux, macOS, Windows), mobile platforms (Android, iOS), as well as
Web-based platforms and [consoles](https://godotengine.org/consoles).

## Free, open source and community-driven

Godot is completely free and open source under the very permissive [MIT license](https://godotengine.org/license).
No strings attached, no royalties, nothing. The users' games are theirs, down
to the last line of engine code. Godot's development is fully independent and
community-driven, empowering users to help shape their engine to match their
expectations. It is supported by the [Godot Foundation](https://godot.foundation/)
not-for-profit.

Before being open sourced in [February 2014](https://github.com/godotengine/godot/commit/0b806ee0fc9097fa7bda7ac0109191c9c5e0a1ac),
Godot had been developed by [Juan Linietsky](https://github.com/reduz) and
[Ariel Manzur](https://github.com/punto-) for several years as an in-house
engine, used to publish several work-for-hire titles.

![Screenshot of a 3D scene in the Godot Engine editor](https://raw.githubusercontent.com/godotengine/godot-design/master/screenshots/editor_tps_demo_1920x1080.jpg)

## Getting the engine

### Binary downloads

Official binaries for the Godot editor and the export templates can be found
[on the Godot website](https://godotengine.org/download).

### Compiling from source

[See the official docs](https://docs.godotengine.org/en/latest/engine_details/development/compiling)
for compilation instructions for every supported platform.

## Community and contributing

Godot is not only an engine but an ever-growing community of users and engine
developers. The main community channels are listed [on the homepage](https://godotengine.org/community).

The best way to get in touch with the core engine developers is to join the
[Godot Contributors Chat](https://chat.godotengine.org).

To get started contributing to the project, see the [contributing guide](CONTRIBUTING.md).
This document also includes guidelines for reporting bugs.

## Documentation and demos

The official documentation is hosted on [Read the Docs](https://docs.godotengine.org).
It is maintained by the Godot community in its own [GitHub repository](https://github.com/godotengine/godot-docs).

The [class reference](https://docs.godotengine.org/en/latest/classes/)
is also accessible from the Godot editor.

We also maintain official demos in their own [GitHub repository](https://github.com/godotengine/godot-demo-projects)
as well as a list of [awesome Godot community resources](https://github.com/godotengine/awesome-godot).

There are also a number of other
[learning resources](https://docs.godotengine.org/en/latest/community/tutorials.html)
provided by the community, such as text and video tutorials, demos, etc.
Consult the [community channels](https://godotengine.org/community)
for more information.

[![Code Triagers Badge](https://www.codetriage.com/godotengine/godot/badges/users.svg)](https://www.codetriage.com/godotengine/godot)
[![Translate on Weblate](https://hosted.weblate.org/widgets/godot-engine/-/godot/svg-badge.svg)](https://hosted.weblate.org/engage/godot-engine/?utm_source=widget)
