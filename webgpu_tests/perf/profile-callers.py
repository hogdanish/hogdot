#!/usr/bin/env python3
"""Attribute a .cpuprofile's self time to (caller -> function) pairs, steady state only.

usage: profile-callers.py file.cpuprofile [top]

The first third of the samples (boot, wasm compile, shader translation) is dropped. Wasm frames
carry mangled names when the template was built with debug_symbols=yes; they are demangled with
c++filt when available.
"""

import json
import subprocess
import sys


def main():
    profile = json.load(open(sys.argv[1]))
    top = int(sys.argv[2]) if len(sys.argv) > 2 else 25
    nodes = {node["id"]: node for node in profile["nodes"]}
    parent = {}
    for node in profile["nodes"]:
        for child in node.get("children", []):
            parent[child] = node["id"]
    samples = profile["samples"]
    start = len(samples) // 3
    used = len(samples) - start
    pairs = {}
    for sample_id in samples[start:]:
        node = nodes[sample_id]
        parent_node = nodes.get(parent.get(sample_id))
        caller = (parent_node["callFrame"]["functionName"] if parent_node else "-") or "(anon)"
        callee = node["callFrame"]["functionName"] or "(anon)"
        pairs[(caller, callee)] = pairs.get((caller, callee), 0) + 1
    rows = sorted(pairs.items(), key=lambda item: -item[1])[:top]
    names = [name for key, _ in rows for name in key]
    demangled = dict(zip(names, names))
    try:
        out = subprocess.run(["c++filt"], input="\n".join(names) + "\n", capture_output=True, text=True, check=False)
        demangled = dict(zip(names, out.stdout.split("\n")))
    except OSError:
        pass
    print(f"steady-state samples: {used}")
    for (caller, callee), count in rows:
        print(
            f"{100 * count / used:5.1f}%  {demangled.get(callee, callee)[:70]:70s} <- {demangled.get(caller, caller)[:60]}"
        )


if __name__ == "__main__":
    main()
