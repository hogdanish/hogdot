def can_build(env, platform):
    # glslang is needed for any RenderingDevice backend (Vulkan, D3D12, Metal, WebGPU).
    # OpenGL/GLES3 doesn't use glslang.
    # NOTE: "webgpu" is read with .get() because config.py is evaluated before the
    # option is guaranteed to be declared. On desktop the earlier terms short-circuit
    # and hide the difference; on web, vulkan/d3d12/metal are all False, so a bare
    # env["webgpu"] is a hard KeyError at configure time. See RL-003.
    return env["vulkan"] or env["d3d12"] or env["metal"] or env.get("webgpu", False)


def configure(env):
    pass
