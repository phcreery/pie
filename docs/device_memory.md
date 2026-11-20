vkdt: owns the device allocator

- Four heaps — connector images, ssbo, staging, uniforms — each backed by a single VkDeviceMemory.
- dt_vkalloc suballocates offsets inside a heap from a free list (offset, size, ref), coalesces on free, and keeps its metadata in
  a preallocated pool so bookkeeping never fragments the real heap. dt_vkfree is refcounted.
- Rebuild (s_graph_run_alloc) = dt_vkalloc_nuke (memset the metadata back to one free block), recompute offsets for every
  connector, and only vkFreeMemory/vkAllocateMemory when the packed layout outgrew the previous block. Otherwise the same device
  memory is reused.
- VkImage/VkImageView/VkBuffer objects are still destroyed and recreated every alloc pass. The saving is per-resource device
  memory allocation, not object churn — my earlier "avoids vkDestroyImage churn" phrasing was wrong.

Constraints it accepts:

- One memoryTypeBits decision per heap, not per resource (checked once, and every resource must live with it).
- Peak footprint is historical max; memory is not returned between passes, and packing waste at alignment boundaries is
  deliberately ignored.
- Explicit lifetime/refcount bookkeeping (connected_mi counters, input aliasing onto upstream outputs) — the pipeline must know
  who still references an output.
- Full rebuild needs a quiesced queue when the GUI may still be sampling the output (vkQueueWaitIdle).

Tradeoff: cheap enough that a full nuke-and-realloc is the only path, so there is no incremental resize logic to get wrong. Cost:
manual memory-type handling, manual lifetimes, and the graph must fit "one allocation per heap".

pie: owns no device memory

- Connector textures/buffers are wgpu.Texture / wgpu.Buffer handles (gpu/Texture.zig:70-99, gpu/Buffer.zig). wgpu native owns the
  underlying VkImage/VkDeviceMemory and does its own suballocation — opaque to pie.
- Consequence: no control over placement, memory type, aliasing, defragmentation, or a "nuke and reuse" operation. Every changed
  resource is an independent create/destroy, whose cost is whatever the driver/wgpu chooses.
- Staging is the one place pie does manage memory: fixed-size upload/download wgpu.Buffers, mapped once and carved with
  zuballoc.SubAllocator (gpu/Buffer.zig:166-179). That is the same offset-suballocation idea as vkdt's heap_staging, but only for
  host-visible staging, and upload_fba.reset() on reroute is its dt_vkalloc_nuke.

Constraints it accepts:

- WebGPU surface: buffer size alignment (4, pie uses 8), no zero-byte buffers, format/usage limits such as r16uint storage needing
  an adapter feature (gpu/Texture.zig:80-83), fixed usage flags.
- No cross-resource lifetime sharing at the API level; Connector.deinit frees exactly one resource.
- Allocation failure is per object, not per heap.

The comparison, condensed

┌──────────────────────────────────┬──────────────────────────────────────────────┬───────────────────────────────────────────┐
│ │ vkdt │ pie │
├──────────────────────────────────┼──────────────────────────────────────────────┼───────────────────────────────────────────┤
│ Who owns device memory │ the pipeline │ wgpu native │
├──────────────────────────────────┼──────────────────────────────────────────────┼───────────────────────────────────────────┤
│ Allocation granularity │ offset in one heap block │ one API object │
├──────────────────────────────────┼──────────────────────────────────────────────┼───────────────────────────────────────────┤
│ Rebuild cost │ O(connectors) metadata + bind │ O(changed objects) driver alloc/free │
├──────────────────────────────────┼──────────────────────────────────────────────┼───────────────────────────────────────────┤
│ Rebuild strategy │ nuke everything, always │ reconcile only mismatched extents/formats │
├──────────────────────────────────┼──────────────────────────────────────────────┼───────────────────────────────────────────┤
│ Memory types / aliasing / defrag │ explicit, controlled │ driver's job, not expressible │
├──────────────────────────────────┼──────────────────────────────────────────────┼───────────────────────────────────────────┤
│ Failure mode │ fragmentation / heap growth / manual ref bug │ driver allocator, opaque │
├──────────────────────────────────┼──────────────────────────────────────────────┼───────────────────────────────────────────┤
│ Peak memory │ historical maximum, monotonically packed │ per-resource, freed immediately │
├──────────────────────────────────┼──────────────────────────────────────────────┼───────────────────────────────────────────┤
│ Portability │ Vulkan-specific │ WebGPU backends │
└──────────────────────────────────┴──────────────────────────────────────────────┴───────────────────────────────────────────┘

The tradeoff that drives pie's design: vkdt can treat "ROI/format changed" as "rebuild the world" because nuking the allocator is
nearly free. Pie cannot assume that, since each replacement is a driver allocation plus a bind-group invalidation epoch bump. So
pie reconciles at the socket level — read the module extent/format, replace only mismatches, sync, mark dirty — and that path only
stays cheap because resource descriptions come from the inherited socket link rather than a per-socket lookup.

If pie ever gains explicit allocator control (raw Vulkan or a wgpu API for memory heaps), the vkdt model becomes viable and the
reconcile pass could collapse into a full rebuild. Until then the constraints are structural: no placement control, no aliasing,
driver-owned suballocation.
