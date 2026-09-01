#!/usr/bin/env python3
"""Audit baked WebGPU shader containers written by an export.

usage: pck-bake-audit.py <project dir>   (scans .godot/**/*.webgpu.cache)

Prints, per ShaderRD cache file, how many variants are present and how many carry baked WGSL
(bit 0 of the WebGPU container header flags). A version with SPIR-V but no WGSL translates live
at runtime through Tint; see the build-export skill for the three ways that happens silently.
"""

import glob
import struct
import sys


def audit(path):
    blob = open(path, "rb").read()
    if blob[:4] != b"GDSC":
        return None
    variant_count = struct.unpack_from("<I", blob, 8)[0]
    pos = 12
    present = 0
    baked = 0
    missing = []
    for index in range(variant_count):
        size = struct.unpack_from("<I", blob, pos)[0]
        pos += 4
        if size == 0:
            continue
        present += 1
        # RenderingShaderContainer::ContainerHeader is five u32 (20 bytes); the WebGPU
        # HeaderData follows it: push_constant_bind_group, push_constant_binding, flags.
        flags = struct.unpack_from("<I", blob, pos + 28)[0]
        if flags & 1:
            baked += 1
        else:
            missing.append(str(index))
        pos += size
    return variant_count, present, baked, missing


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    total_present = 0
    total_baked = 0
    for path in sorted(glob.glob(f"{root}/.godot/**/*.webgpu.cache", recursive=True)):
        result = audit(path)
        if result is None:
            continue
        variant_count, present, baked, missing = result
        total_present += present
        total_baked += baked
        parts = path.split("/")
        note = "" if not missing else "no WGSL for variants " + ",".join(missing)
        print(
            f"{parts[-3]:32s} {parts[-1][:8]} variants={variant_count:2d} present={present:2d} wgsl={baked:2d} {note}"
        )
    print(f"present variants {total_present}, with baked WGSL {total_baked}")
    return 0 if total_present == total_baked else 1


if __name__ == "__main__":
    sys.exit(main())
