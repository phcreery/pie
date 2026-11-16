3. Redundant work, ranked

 R1 — o-display performs a full-frame GPU→staging copy every dirty run. enqueueNode .sink always enqueues enqueueTexToBuf (pipeline.zig:1787); runNodesDownloadSink then returns
 early by name (:1811) without ever mapping or reading. For DSC_6765 that's a 2008×3008 RGBA16 texture: ≈48 MB read + ≈48 MB written into a MAP_READ (host-visible) buffer, per
 tick, for nothing. This is the single largest avoidable transfer in the app. vkdt's display sink has no write_sink and never touches staging.

 R2 — compute pipelines and bind groups are rebuilt per dirty node per fresh frame and leak. runNodesCreateBindings unconditionally does node.compute_pipeline = pipeline /
 node.bindings = bindings (:1449, :1461) without deiniting the previous pair; Node.deinit only runs when the node is removed. Each rebuild leaks 1 compute pipeline, 2 bind-group
 layouts, 1 pipeline layout and 2 bind groups per dirty node; Bindings.init also creates texture views it never releases (gpu/Bindings.zig:56-60; deinit only drops bind groups).
 Under a slider drag this is unbounded GPU-object growth plus real driver-side pipeline-creation cost in the hot path. vkdt only creates pipelines/descriptors on
 s_graph_run_alloc.
 [INFERENCE: leaked bind groups keep refs on connector textures; VRAM stays bounded because connectors are reused, object count does not.]

 R3 — two full-res passes for what one can do. format only casts u16→f32 (u16_to_f32_rggb.wgsl) and denoise only normalizes black/white (interpolation.wgsl). 24.15 MP: 48 MB read
 + 97 MB write, then 97 MB read + 97 MB write, and two 97 MB intermediates (connector per node output, Texture.init at :1294). Folding the cast into the normalize pass (read
 r16uint, write r32float) removes one pass and one 97 MB texture with no module-boundary change. Total texture footprint today is ≈435 MB for a 16 MP sensor (48 + 97 + 97 + 4×48).

 R4 — crop runs a resample pass even when rotation is 0. rotate_center.wgsl is a full textureLoad/textureStore sweep with round() sampling; at the default rotation=0,
 meta_rotation_deg=0 it is an identity copy over 6.04 M px. vkdt also copies at 0°, but only inside a crop-sized ROI and with texelFetch (modules/crop/main.comp:49-55). Cheapest
 fix is a bypass, not a faster shader.

 R5 — thumbnails run the full chain, then downscale. graphs.recommend inserts downscale after upstream(sink) (graphs.zig:104, appendDownscale:140), so a 256 px catalog thumb still
 pays format+denoise at 24 MP and crop/colour/filmcurv at 6 MP before shrinking. vkdt caps the sink ROI (max_wd/max_ht → backward ROI, graph-run-modules.h:400-413) and the whole
 tail runs at thumbnail size. This is the biggest win available for catalog scan time.

 R6 — runNodesUploadParams ignores the dirty set. All modules are re-packed and memcpy'd each dirty run (:1563-1622). CPU-only, but it also re-runs Param.layoutTaggedUnion and
 std140.layoutStruct per module per frame (allocating a 1 KB arena buffer each time).

 R7 — run_size is never refreshed when an ROI changes. runNodesInitConnectorTextures refresh updates sock.roi and the texture (:1300-1332), but dispatch counts come from
 node.run_size captured in createNodes (:1738). crop swaps w/h for 90°/270° (crop/module.zig:modifyOut), and downscale changes the ROI on max_edge — both will reallocate the
 texture while dispatching the old grid: under-dispatch (unwritten pixels) or over-dispatch (wasted work). The existing test "swap-roi …" checks the texture ROI and the sink run
 count, not the pixels, so it doesn't catch it.

 R8 — nothing ever frees connectors/textures on graph edits. freeUnusedConnectors is commented out (:712) and clear() explicitly leaves connectors alone (:795-801); there is no
 connector_pool.remove call anywhere. Opening another image in the editor (or undo) creates new module connectors, so the previous graph's textures are orphaned — ≈435 MB per
 open. Param buffers are likewise recreated on every reroute without freeing the previous GPU buffers (current working-tree change at :1067-1116).

 R9 — logging in the hot path. printReport() every run (:752, std.debug.print in pipeline_perf.zig:162) and the full ASCII node graph on every reroute (:715). With a slider-driven
 60 Hz loop that is per-frame terminal I/O.

 R10 (quality, not speed) — no mip chain: the blit samples with textureLod(..., 0) and LINEAR minification (src/gui/texview.glsl), so zoomed-out views alias; vkdt builds 4 mips
 for the display image.

 4. vkdt mechanisms worth copying (not features)

 - Connector bypass/aliasing — dt_connector_bypass (modules/api.h:138-155) makes a module emit no node and no buffer; used by denoise/hilite/demosaic. You have no equivalent, so
   every module is always a physical pass + texture. This is exactly what R3/R4 want.
 - Liveness aliasing — allocation walks topological order, frees a buffer after its last consumer, and later nodes reuse the offset (graph-run-nodes-allocate.h:950-981, 605-623).
   No inter-node copies in either codebase; the difference is peak VRAM, not bandwidth.
 - ROI scaling from the sink — max_wd/max_ht scales the backward ROI, and create_nodes picks a cheaper topology at that scale (graph-run-modules.h:400-413, demosaic/main.c:92-99).
   This is how vkdt gets cheap thumbnails/previews; you have ROI.x/y unused and no scale path (Encoder.enqueueBufToTex hardcodes origin 0).
 - Record-only runs don't recreate pipelines — reuse node.compute_pipeline/bindings while ROI, formats and buffer identities are unchanged.
 - Per-node GPU timestamps — vkdt's query[2] pools give per-node ms (graph.c:123-135); your PerfMetrics is CPU wall-clock laps only, so you can't see that the sink copy or a
   pipeline rebuild dominates.