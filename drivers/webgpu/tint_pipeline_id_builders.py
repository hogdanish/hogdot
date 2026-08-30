"""Build-time generator for the Tint translation-pipeline stamp.

Lives in drivers/webgpu/ rather than beside its first consumer in
editor/shader/shader_baker/ because CI deletes the whole editor/ tree before
every export-template build (.github/actions/godot-build), and the template's
own copy of the stamp -- drivers/webgpu/SCsub -- has to be generatable without
it. Both SCsubs share this one module so the two headers agree by construction.
"""

import hashlib
import os


def make_tint_pipeline_id_header(target, source, env):
    """Hash the translation-defining inputs of tint_convert_cli into a header.

    source[0] is drivers/webgpu/tint_cli/pipeline_id_inputs.txt; the hash is
    sha256 over the concatenated contents of the files it lists, in order,
    truncated to 16 hex chars — the same computation tint_cli/build.sh embeds
    into the CLI binary, so the editor can detect a stale CLI at bake time.
    """
    list_path = str(source[0])
    repo_root = env.Dir("#").abspath
    digest = hashlib.sha256()
    with open(list_path, encoding="utf-8") as list_file:
        for line in list_file:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            with open(os.path.join(repo_root, line), "rb") as input_file:
                digest.update(input_file.read())
    pipeline_id = digest.hexdigest()[:16]

    with open(str(target[0]), "w", encoding="utf-8") as header:
        header.write("/* THIS FILE IS GENERATED DO NOT EDIT */\n")
        header.write("#pragma once\n")
        header.write(f'#define TINT_BAKE_PIPELINE_ID "{pipeline_id}"\n')


def pipeline_id_dependency(env, inputs_file):
    """Return the build dependency for the generated stamp header.

    ⚠ NOT a list of File() nodes for the listed inputs, which is what this used
    to be. Some of those inputs INCLUDE the generated header --
    rendering_device_driver_webgpu.cpp publishes the stamp on the __cgPerf
    channel -- so declaring them as File() dependencies makes SCons scan them,
    find the header they include, and abort the build with

        Found dependency cycle(s):
          drivers/webgpu/tint_pipeline_id.gen.h -> drivers/webgpu/tint_pipeline_id.gen.h

    even though there is no cycle in time: the header is generated from the
    file's CONTENT, not from its compiled object. Depending on a Value() of the
    digest expresses exactly that. It regenerates the header whenever any input
    changes, carries no scannable edges, and cannot be defeated by a future
    input that happens to include the header too.
    """
    digest = hashlib.sha256()
    repo_root = env.Dir("#").abspath
    with open(inputs_file.abspath, encoding="utf-8") as list_file:
        for line in list_file:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            with open(os.path.join(repo_root, line), "rb") as input_file:
                digest.update(input_file.read())
    return [inputs_file, env.Value(digest.hexdigest())]
