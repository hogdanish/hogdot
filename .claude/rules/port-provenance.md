# Port provenance (the law that makes this fork maintainable)

Every line hogdot carries over mainline must be traceable to the GodotWebGPU commit it came from.
Without that, the next rebase-forward has no way to tell a WebGPU change from an upstream one, and the
fork becomes unmaintainable. This is the single most important convention in the repository.

- **Every port commit cites its source.** End the message with the upstream SHAs it carries:

  ```
  port(rd): carry WebGPU driver hooks into RenderingDevice

  Webgpu-Port: rd-core
  Webgpu-Source: f8b3cd0 04713ba 137a252
  ```

  `Webgpu-Port` is the slice name from CLAUDE.md's grouping; `Webgpu-Source` is one or more short SHAs
  from `git log 4.6.2-stable..webgpu/webgpu-4.6.2`. Find them with
  `git log --oneline 4.6.2-stable..webgpu/webgpu-4.6.2 -- <path>`.
- **Adapted ≠ copied.** When a hunk could not be applied as written because mainline moved underneath
  it, say so in the commit body — what the fork did, what 4.7.1 changed, and why your version differs.
  That paragraph is the thing a future maintainer needs and cannot reconstruct.
- ⚠ **Never silently drop a hunk.** If part of the fork's delta is deliberately not carried (an
  unrelated refactor, something 4.7.1 already does, a `webgpu_site/` marketing asset), state it in the
  commit body. A dropped hunk with no record is indistinguishable from an oversight forever after.
- **Do not rewrite the `webgpu` or `upstream` remote refs.** They are the evidence. Both have their
  push URLs disabled; keep it that way.
- Mixing a port commit with unrelated cleanup destroys the audit trail — keep them separate.
