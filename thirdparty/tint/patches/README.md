# Tint Patches for Godot WebGPU

These patches modify the vendored Tint source for Godot's WebGPU backend.
They are applied on top of clean upstream Tint extracted via `extract_tint.sh`.

## Applying

From the repository root:

```bash
for p in thirdparty/tint/patches/*.patch; do
    patch -p1 < "$p"
done
```

## Patch Summary

| Patch | Files | Group | Description |
|-------|-------|-------|-------------|
| 0001 | validate.cc | UBO layout | `SetSkipBlockLayout(true)` + improved error messages |
| 0002 | validator.h, validator.cc, reader.cc | Spec constants | `kAllowStructMemberSizeMismatch` capability |
| 0003 | decompose_strided_array.cc | Spec constants | Skip padding when stride < element size |
| 0004 | shader_io.cc | Point size | Accept non-constant `point_size` stores |
| 0005 | ir_to_program.cc | Spec constants | `@size` emission guard + capability |
| 0006 | parse_num.cc | Vendoring | Replace `absl::from_chars` with `std::from_chars` |
| 0007 | reader/lower/texture.cc | Handle params | Drop unreachable functions before texture lowering |
| 0008 | ice.h, ice.cc | Crash containment | Process-global ICE handler that may longjmp instead of trapping |

## Logical Groups

**Group A — UBO Layout (0001)**: Godot uses C++ struct packing for uniform buffers,
not std140/std430. Always necessary.

**Group B — Specialization Constants (0002, 0003, 0005)**: Godot's specialization
constants can change struct/array sizes at runtime, creating size mismatches that
Tint's IR validator and lowering passes don't expect. These patches relax validation
and prevent invalid WGSL output.

**Group C — Point Size (0004)**: Godot shaders pass through `gl_PointSize` with
non-constant values. Tint strips point_size during lowering but validates the stored
value first. This patch relaxes that validation. Could potentially be moved to
`spirv_preprocess.cpp` or proposed upstream.

**Group D — Vendoring (0006)**: Replaces Abseil dependency with C++17 `std::from_chars`.
Always necessary when vendoring without Abseil.

**Group E — Handle parameters (0007)**: `ConvertUserCall` forks a function when a call
site converts one of its handle parameters, retargets that call, and destroys the
original only if no *call* usage remains. An original kept alive solely by another dead
original survives with parameters still typed `spirv.image`; its texture builtins are
still in `ir.Instructions()`, so the lowering asserts on a non-texture type. The patch
sweeps functions unreachable from any entry point after `UpdateValues()`. Godot 4.7.1
hits this through `area_lights_inc.glsl`, whose LTC helpers take `texture2D`/`sampler2D`
parameters and are called from more than one site — added by area lights, which do not
exist in 4.6.2, which is why GodotWebGPU never saw it. This one is a genuine upstream
Tint bug and is the best candidate of the seven for an upstream report.

**Group F — Crash containment (0008)**: every `TINT_ASSERT`/`TINT_ICE`/`TINT_UNREACHABLE`
ends in a `[[noreturn]]` destructor that traps the process. In a wasm build that aborts
the module and permanently kills the browser main loop, so one untranslatable shader
(e.g. a switch fallthrough, which the SPIR-V reader asserts on) takes the whole tab
down. The patch adds `SetInternalCompilerErrorHandler()`, a process-global hook the
destructor consults first; unlike the per-call callback it may transfer control away
(longjmp) instead of returning. `drivers/webgpu/tint_wrapper.cpp` installs a handler
that longjmps back to the `SpirvToWgsl` call site, so an ICE reports as an ordinary
translation failure and the engine falls back to an invalid-shader material.

## Upstream Source

Tint is extracted from [Dawn](https://dawn.googlesource.com/dawn) using
`extract_tint.sh`. The patches were generated against upstream `main` and verified
to apply cleanly and produce identical output via round-trip testing.
