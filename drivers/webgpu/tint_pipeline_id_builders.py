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
