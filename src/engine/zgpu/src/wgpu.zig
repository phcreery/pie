const std = @import("std");
pub const c = @cImport(@cInclude("webgpu/webgpu.h"));
pub const slog = std.log.scoped(.wgpu);

pub const True = OptionalBool.true;
pub const False = OptionalBool.false;

//
// Section: Enums
//

pub const OptionalBool = enum(u32) {
    false = 0x00000000,
    true = 0x00000001,
    undefined = 0x00000002,
};

pub const Status = enum(u32) {
    success = 0x00000001,
    @"error" = 0x00000002,
};

pub const WaitStatus = enum(u32) {
    success = 0x00000001,
    timed_out = 0x00000002,
    @"error" = 0x00000003,
};

pub const CallbackMode = enum(u32) {
    undefined = 0x00000000,
    wait_any_only = 0x00000001,
    allow_process_events = 0x00000002,
    allow_spontaneous = 0x00000003,
};

pub const InstanceFeatureName = enum(u32) {
    timed_wait_any = 0x00000001,
    shader_source_spirv = 0x00000002,
    multiple_devices_per_adapter = 0x00000003,
};

pub const AdapterType = enum(u32) {
    undefined = 0x00000000,
    discrete_gpu,
    integrated_gpu,
    cpu,
    unknown,
};

pub const AddressMode = enum(u32) {
    undefined = 0x00000000,
    clamp_to_edge = 0x00000001,
    repeat = 0x00000002,
    mirror_repeat = 0x00000003,
};

pub const CompositeAlphaMode = enum(u32) {
    auto = 0x00000000,
    @"opaque" = 0x00000001,
    premultiplied = 0x00000002,
    unpremultiplied = 0x00000003,
    inherit = 0x00000004,
};

pub const BackendType = enum(u32) {
    undefined = 0x00000000,
    null,
    webgpu,
    d3d11,
    d3d12,
    metal,
    vulkan,
    opengl,
    opengles,
};

pub const BlendFactor = enum(u32) {
    undefined = 0x00000000,
    zero = 0x00000001,
    one = 0x00000002,
    src = 0x00000003,
    one_minus_src = 0x00000004,
    src_alpha = 0x00000005,
    one_minus_src_alpha = 0x00000006,
    dst = 0x00000007,
    one_minus_dst = 0x00000008,
    dst_alpha = 0x00000009,
    one_minus_dst_alpha = 0x0000000A,
    src_alpha_saturated = 0x0000000B,
    constant = 0x0000000C,
    one_minus_constant = 0x0000000D,
    src1 = 0x0000000E,
    one_minus_src1 = 0x0000000F,
    src1_alpha = 0x00000010,
    one_minus_src1_alpha = 0x00000011,
};

pub const BlendOperation = enum(u32) {
    undefined = 0x00000000,
    add = 0x00000001,
    subtract = 0x00000002,
    reverse_subtract = 0x00000003,
    min = 0x00000004,
    max = 0x00000005,
};

pub const BufferBindingType = enum(u32) {
    binding_not_used = 0x00000000,
    undefined = 0x00000001,
    uniform = 0x00000002,
    storage = 0x00000003,
    read_only_storage = 0x00000004,
};

pub const MapAsyncStatus = enum(u32) {
    success = 0x00000001,
    callback_cancelled = 0x00000002,
    @"error" = 0x00000003,
    aborted = 0x00000004,
};

pub const BufferMapState = enum(u32) {
    unmapped = 0x00000001,
    pending = 0x00000002,
    mapped = 0x00000003,
};

pub const CompareFunction = enum(u32) {
    undefined = 0x00000000,
    never = 0x00000001,
    less = 0x00000002,
    equal = 0x00000003,
    less_equal = 0x00000004,
    greater = 0x00000005,
    not_equal = 0x00000006,
    greater_equal = 0x00000007,
    always = 0x00000008,
};

pub const CompilationInfoRequestStatus = enum(u32) {
    success = 0x00000001,
    callback_cancelled = 0x00000002,
};

pub const CompilationMessageType = enum(u32) {
    @"error" = 0x00000001,
    warning = 0x00000002,
    info = 0x00000003,
};

pub const CreatePipelineAsyncStatus = enum(u32) {
    success = 0x00000001,
    callback_cancelled = 0x00000002,
    validation_error = 0x00000003,
    internal_error = 0x00000004,
};

pub const CullMode = enum(u32) {
    undefined = 0x00000000,
    none = 0x00000001,
    front = 0x00000002,
    back = 0x00000003,
};

pub const DeviceLostReason = enum(u32) {
    unknown = 0x00000001,
    destroyed = 0x00000002,
    callback_cancelled = 0x00000003,
    failed_creation = 0x00000004,
};

pub const ErrorFilter = enum(u32) {
    validation = 0x00000001,
    out_of_memory = 0x00000002,
    internal = 0x00000003,
};

pub const ErrorType = enum(u32) {
    no_error = 0x00000001,
    validation = 0x00000002,
    out_of_memory = 0x00000003,
    internal = 0x00000004,
    unknown = 0x00000005,
};

pub const FeatureLevel = enum(u32) {
    undefined = 0x00000000,
    compatibility = 0x00000001,
    core = 0x00000002,
};

pub const FeatureName = enum(u32) {
    core_features_and_limits = 0x00000001,
    depth_clip_control = 0x00000002,
    depth32_float_stencil8 = 0x00000003,
    texture_compression_bc = 0x00000004,
    texture_compression_bc_sliced_3d = 0x00000005,
    texture_compression_etc2 = 0x00000006,
    texture_compression_astc = 0x00000007,
    texture_compression_astc_sliced_3d = 0x00000008,
    timestamp_query = 0x00000009,
    indirect_first_instance = 0x0000000A,
    shader_f16 = 0x0000000B,
    rg11_b10_ufloat_renderable = 0x0000000C,
    bgra8_unorm_storage = 0x0000000D,
    float32_filterable = 0x0000000E,
    float32_blendable = 0x0000000F,
    clip_distances = 0x00000010,
    dual_source_blending = 0x00000011,
    subgroups = 0x00000012,
    texture_formats_tier1 = 0x00000013,
    texture_formats_tier2 = 0x00000014,
    //...
    chromium_experimental_timestamp_query_inside_passes = 0x00050003,
    //...
};

pub const FilterMode = enum(u32) {
    undefined = 0x00000000,
    nearest = 0x00000001,
    linear = 0x00000002,
};

pub const MipmapFilterMode = enum(u32) {
    undefined = 0x00000000,
    nearest = 0x00000001,
    linear = 0x00000002,
};

pub const FrontFace = enum(u32) {
    undefined = 0x00000000,
    ccw = 0x00000001,
    cw = 0x00000002,
};

pub const IndexFormat = enum(u32) {
    undefined = 0x00000000,
    uint16 = 0x00000001,
    uint32 = 0x00000002,
};

pub const LoadOp = enum(u32) {
    undefined = 0x00000000,
    load = 0x00000001,
    clear = 0x00000002,
};

pub const PowerPreference = enum(u32) {
    undefined = 0x00000000,
    low_power = 0x00000001,
    high_performance = 0x00000002,
};

pub const PresentMode = enum(u32) {
    undefined = 0x00000000,
    fifo = 0x00000001,
    fifo_relaxed = 0x00000002,
    immediate = 0x00000003,
    mailbox = 0x00000004,
};

pub const PrimitiveTopology = enum(u32) {
    undefined = 0x00000000,
    point_list = 0x00000001,
    line_list = 0x00000002,
    line_strip = 0x00000003,
    triangle_list = 0x00000004,
    triangle_strip = 0x00000005,
};

pub const QueryType = enum(u32) {
    occlusion = 0x00000001,
    timestamp = 0x00000002,
};

pub const QueueWorkDoneStatus = enum(u32) {
    success = 0x00000001,
    callback_cancelled = 0x00000002,
    @"error" = 0x00000003,
};

pub const PopErrorScopeStatus = enum(u32) {
    success = 0x00000001,
    callback_cancelled = 0x00000002,
    @"error" = 0x00000003,
};

pub const RequestAdapterStatus = enum(u32) {
    success = 0x00000001,
    callback_cancelled = 0x00000002,
    unavailable = 0x00000003,
    @"error" = 0x00000004,
};

pub const RequestDeviceStatus = enum(u32) {
    success = 0x00000001,
    callback_cancelled = 0x00000002,
    @"error" = 0x00000003,
};

pub const SurfaceGetCurrentTextureStatus = enum(u32) {
    success_optimal = 0x00000001,
    success_suboptimal = 0x00000002,
    timeout = 0x00000003,
    outdated = 0x00000004,
    lost = 0x00000005,
    @"error" = 0x00000006,
};

pub const SType = enum(u32) {
    shader_source_spirv = 0x00000001,
    shader_source_wgsl = 0x00000002,
    render_pass_max_draw_count = 0x00000003,
    surface_source_metal_layer = 0x00000004,
    surface_source_windows_hwnd = 0x00000005,
    surface_source_xlib_window = 0x00000006,
    surface_source_wayland_surface = 0x00000007,
    surface_source_android_native_window = 0x00000008,
    surface_source_xcb_window = 0x00000009,
    surface_color_management = 0x0000000A,
    request_adapter_webxr_options = 0x0000000B,
    //...
    dawn_toggles_descriptor = 0x0005000A,
    //...
};

pub const SamplerBindingType = enum(u32) {
    binding_not_used = 0x00000000,
    undefined = 0x00000001,
    filtering = 0x00000002,
    non_filtering = 0x00000003,
    comparison = 0x00000004,
};

pub const StencilOperation = enum(u32) {
    undefined = 0x00000000,
    keep = 0x00000001,
    zero = 0x00000002,
    replace = 0x00000003,
    invert = 0x00000004,
    increment_clamp = 0x00000005,
    decrement_clamp = 0x00000006,
    increment_wrap = 0x00000007,
    decrement_wrap = 0x00000008,
};

pub const StorageTextureAccess = enum(u32) {
    binding_not_used = 0x00000000,
    undefined = 0x00000001,
    write_only = 0x00000002,
    read_only = 0x00000003,
    read_write = 0x00000004,
};

pub const StoreOp = enum(u32) {
    undefined = 0x00000000,
    store = 0x00000001,
    discard = 0x00000002,
};

pub const TextureAspect = enum(u32) {
    undefined = 0x00000000,
    all = 0x00000001,
    stencil_only = 0x00000002,
    depth_only = 0x00000003,
};

pub const TextureDimension = enum(u32) {
    undefined = 0x00000000,
    tdim_1d = 0x00000001,
    tdim_2d = 0x00000002,
    tdim_3d = 0x00000003,
};

pub const TextureFormat = enum(u32) {
    undefined = 0x00000000,
    r8_unorm = 0x00000001,
    r8_snorm = 0x00000002,
    r8_uint = 0x00000003,
    r8_sint = 0x00000004,
    r16_unorm = 0x00000005,
    r16_snorm = 0x00000006,
    r16_uint = 0x00000007,
    r16_sint = 0x00000008,
    r16_float = 0x00000009,
    rg8_unorm = 0x0000000A,
    rg8_snorm = 0x0000000B,
    rg8_uint = 0x0000000C,
    rg8_sint = 0x0000000D,
    r32_float = 0x0000000E,
    r32_uint = 0x0000000F,
    r32_sint = 0x00000010,
    rg16_unorm = 0x00000011,
    rg16_snorm = 0x00000012,
    rg16_uint = 0x00000013,
    rg16_sint = 0x00000014,
    rg16_float = 0x00000015,
    rgba8_unorm = 0x00000016,
    rgba8_unorm_srgb = 0x00000017,
    rgba8_snorm = 0x00000018,
    rgba8_uint = 0x00000019,
    rgba8_sint = 0x0000001A,
    bgra8_unorm = 0x0000001B,
    bgra8_unorm_srgb = 0x0000001C,
    rgb10_a2_uint = 0x0000001D,
    rgb10_a2_unorm = 0x0000001E,
    rg11_b10_ufloat = 0x0000001F,
    rgb9_e5_ufloat = 0x00000020,
    rg32_float = 0x00000021,
    rg32_uint = 0x00000022,
    rg32_sint = 0x00000023,
    rgba16_unorm = 0x00000024,
    rgba16_snorm = 0x00000025,
    rgba16_uint = 0x00000026,
    rgba16_sint = 0x00000027,
    rgba16_float = 0x00000028,
    rgba32_float = 0x00000029,
    rgba32_uint = 0x0000002A,
    rgba32_sint = 0x0000002B,
    stencil8 = 0x0000002C,
    depth16_unorm = 0x0000002D,
    depth24_plus = 0x0000002E,
    depth24_plus_stencil8 = 0x0000002F,
    depth32_float = 0x00000030,
    depth32_float_stencil8 = 0x00000031,
    bc1_rgba_unorm = 0x00000032,
    bc1_rgba_unorm_srgb = 0x00000033,
    bc2_rgba_unorm = 0x00000034,
    bc2_rgba_unorm_srgb = 0x00000035,
    bc3_rgba_unorm = 0x00000036,
    bc3_rgba_unorm_srgb = 0x00000037,
    bc4_r_unorm = 0x00000038,
    bc4_r_snorm = 0x00000039,
    bc5_rg_unorm = 0x0000003A,
    bc5_rg_snorm = 0x0000003B,
    bc6_hrgb_ufloat = 0x0000003C,
    bc6_hrgb_float = 0x0000003D,
    bc7_rgba_unorm = 0x0000003E,
    bc7_rgba_unorm_srgb = 0x0000003F,
    etc2_rgb8_unorm = 0x00000040,
    etc2_rgb8_unorm_srgb = 0x00000041,
    etc2_rgb8_a1_unorm = 0x00000042,
    etc2_rgb8_a1_unorm_srgb = 0x00000043,
    etc2_rgba8_unorm = 0x00000044,
    etc2_rgba8_unorm_srgb = 0x00000045,
    eacr11_unorm = 0x00000046,
    eacr11_snorm = 0x00000047,
    eacrg11_unorm = 0x00000048,
    eacrg11_snorm = 0x00000049,
    astc4x4_unorm = 0x0000004A,
    astc4x4_unorm_srgb = 0x0000004B,
    astc5x4_unorm = 0x0000004C,
    astc5x4_unorm_srgb = 0x0000004D,
    astc5x5_unorm = 0x0000004E,
    astc5x5_unorm_srgb = 0x0000004F,
    astc6x5_unorm = 0x00000050,
    astc6x5_unorm_srgb = 0x00000051,
    astc6x6_unorm = 0x00000052,
    astc6x6_unorm_srgb = 0x00000053,
    astc8x5_unorm = 0x00000054,
    astc8x5_unorm_srgb = 0x00000055,
    astc8x6_unorm = 0x00000056,
    astc8x6_unorm_srgb = 0x00000057,
    astc8x8_unorm = 0x00000058,
    astc8x8_unorm_srgb = 0x00000059,
    astc10x5_unorm = 0x0000005A,
    astc10x5_unorm_srgb = 0x0000005B,
    astc10x6_unorm = 0x0000005C,
    astc10x6_unorm_srgb = 0x0000005D,
    astc10x8_unorm = 0x0000005E,
    astc10x8_unorm_srgb = 0x0000005F,
    astc10x10_unorm = 0x00000060,
    astc10x10_unorm_srgb = 0x00000061,
    astc12x10_unorm = 0x00000062,
    astc12x10_unorm_srgb = 0x00000063,
    astc12x12_unorm = 0x00000064,
    astc12x12_unorm_srgb = 0x00000065,
    r8_bg8_biplanar420_unorm = 0x00050000,
    r10_x6_bg10_x6_biplanar420_unorm = 0x00050001,
    r8_bg8_a8_triplanar420_unorm = 0x00050002,
    r8_bg8_biplanar422_unorm = 0x00050003,
    r8_bg8_biplanar444_unorm = 0x00050004,
    r10_x6_bg10_x6_biplanar422_unorm = 0x00050005,
    r10_x6_bg10_x6_biplanar444_unorm = 0x00050006,
    opaque_y_cb_cr_android = 0x00050007,
};

pub const TextureSampleType = enum(u32) {
    binding_not_used = 0x00000000,
    undefined = 0x00000001,
    float = 0x00000002,
    unfilterable_float = 0x00000003,
    depth = 0x00000004,
    sint = 0x00000005,
    uint = 0x00000006,
};

pub const TextureViewDimension = enum(u32) {
    undefined = 0x00000000,
    tvdim_1d = 0x00000001,
    tvdim_2d = 0x00000002,
    tvdim_2d_array = 0x00000003,
    tvdim_cube = 0x00000004,
    tvdim_cube_array = 0x00000005,
    tvdim_3d = 0x00000006,
};

pub const VertexFormat = enum(u32) {
    undefined = 0x00000000,
    uint8 = 0x00000001,
    uint8x2 = 0x00000002,
    uint8x4 = 0x00000003,
    sint8 = 0x00000004,
    sint8x2 = 0x00000005,
    sint8x4 = 0x00000006,
    unorm8 = 0x00000007,
    unorm8x2 = 0x00000008,
    unorm8x4 = 0x00000009,
    snorm8 = 0x0000000A,
    snorm8x2 = 0x0000000B,
    snorm8x4 = 0x0000000C,
    uint16 = 0x0000000D,
    uint16x2 = 0x0000000E,
    uint16x4 = 0x0000000F,
    sint16 = 0x00000010,
    sint16x2 = 0x00000011,
    sint16x4 = 0x00000012,
    unorm16 = 0x00000013,
    unorm16x2 = 0x00000014,
    unorm16x4 = 0x00000015,
    snorm16 = 0x00000016,
    snorm16x2 = 0x00000017,
    snorm16x4 = 0x00000018,
    float16 = 0x00000019,
    float16x2 = 0x0000001A,
    float16x4 = 0x0000001B,
    float32 = 0x0000001C,
    float32x2 = 0x0000001D,
    float32x3 = 0x0000001E,
    float32x4 = 0x0000001F,
    uint32 = 0x00000020,
    uint32x2 = 0x00000021,
    uint32x3 = 0x00000022,
    uint32x4 = 0x00000023,
    sint32 = 0x00000024,
    sint32x2 = 0x00000025,
    sint32x3 = 0x00000026,
    sint32x4 = 0x00000027,
    unorm10_10_10_2 = 0x00000028,
    unorm8x4_bgra = 0x00000029,
};

pub const VertexStepMode = enum(u32) {
    undefined = 0x00000000,
    vertex = 0x00000001,
    instance = 0x00000002,
};

//
// Section: Flags
//

pub const Flags = u64;

pub const BufferUsage = packed struct(Flags) {
    map_read: bool = false,
    map_write: bool = false,
    copy_src: bool = false,
    copy_dst: bool = false,
    index: bool = false,
    vertex: bool = false,
    uniform: bool = false,
    storage: bool = false,
    indirect: bool = false,
    query_resolve: bool = false,
    _padding: u54 = 0,
};

pub const ColorWriteMask = packed struct(Flags) {
    red: bool = false,
    green: bool = false,
    blue: bool = false,
    alpha: bool = false,
    _padding: u60 = 0,

    pub const all = ColorWriteMask{ .red = true, .green = true, .blue = true, .alpha = true };
};

pub const MapMode = packed struct(Flags) {
    read: bool = false,
    write: bool = false,
    _padding: u62 = 0,
};

pub const ShaderStage = packed struct(Flags) {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,
    _padding: u61 = 0,
};

pub const TextureUsage = packed struct(Flags) {
    copy_src: bool = false,
    copy_dst: bool = false,
    texture_binding: bool = false,
    storage_binding: bool = false,
    render_attachment: bool = false,
    transient_attachment: bool = false,
    _padding: u58 = 0,
};

//
// Section: Surface Sources
//

pub const SurfaceSourceMetalLayer = extern struct {
    chain: ChainedStruct,
    layer: *anyopaque,
};

pub const SurfaceSourceWaylandSurface = extern struct {
    chain: ChainedStruct,
    display: *anyopaque,
    surface: *anyopaque,
};

pub const SurfaceSourceWindowsHWND = extern struct {
    chain: ChainedStruct,
    hinstance: *anyopaque,
    hwnd: *anyopaque,
};

pub const SurfaceSourceXlibWindow = extern struct {
    chain: ChainedStruct,
    display: *anyopaque,
    window: u32,
};

//
// Section: Extern Structs
//

pub const Future = extern struct {
    id: u64 = 0,
};

pub const FutureWaitInfo = extern struct {
    future: Future = .{},
    completed: c.WGPUBool = c.WGPU_FALSE,
};

pub const ChainedStruct = extern struct {
    next: ?*const ChainedStruct,
    struct_type: SType,
};

pub const ChainedStructOut = extern struct {
    next: ?*ChainedStructOut,
    struct_type: SType,
    const _skip_abi_compat = true;
};

pub const StringView = extern struct {
    pub const C = c.WGPUStringView;
    data: ?[*]const u8,
    length: usize,

    pub fn initC() c.WGPUStringView {
        return c.WGPUStringView{
            .data = null,
            .length = 0,
        };
    }
    pub fn cFromZig(str: []const u8) c.WGPUStringView {
        return c.WGPUStringView{
            .data = str.ptr,
            .length = str.len,
        };
    }
    pub fn zigFromC(str: c.WGPUStringView) ?[]const u8 {
        if (str.length < 1) return null;
        return str.data[0..str.length];
    }
};

// Can be chained in InstanceDescriptor
// Can be chained in RequestAdapterOptions
// Can be chained in DeviceDescriptor
pub const DawnTogglesDescriptor = extern struct {
    chain: ChainedStruct = .{ .next = null, .struct_type = .dawn_toggles_descriptor },
    enabled_toggles_count: usize = 0,
    enabled_toggles: ?[*]const [*:0]const u8 = null,
    disabled_toggles_count: usize = 0,
    disabled_toggles: ?[*]const [*:0]const u8 = null,
};

pub const AdapterInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    vendor_name: c.WGPUStringView = .{},
    architecture: c.WGPUStringView = .{},
    device: c.WGPUStringView = .{},
    description: c.WGPUStringView = .{},
    backend_type: BackendType = .undefined,
    adapter_type: AdapterType = .unknown,
    vendor_id: u32 = 0,
    device_id: u32 = 0,
    subgroup_min_size: u32 = 0,
    subgroup_max_size: u32 = 0,
};

pub const RequestAdapterCallbackInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    mode: CallbackMode = .undefined,
    callback: ?RequestAdapterCallback = null,
    userdata_1: ?*anyopaque = null,
    userdata_2: ?*anyopaque = null,
};

pub const RequestDeviceCallbackInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    mode: CallbackMode = .undefined,
    callback: ?RequestDeviceCallback = null,
    userdata_1: ?*anyopaque = null,
    userdata_2: ?*anyopaque = null,
};

pub const DeviceLostCallbackInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    mode: CallbackMode = .undefined,
    callback: ?DeviceLostCallback = null,
    userdata_1: ?*anyopaque = null,
    userdata_2: ?*anyopaque = null,
};

pub const UncapturedErrorCallbackInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    callback: ?UncapturedErrorCallback = null,
    userdata_1: ?*anyopaque = null,
    userdata_2: ?*anyopaque = null,
};

pub const BufferMapCallbackInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    mode: CallbackMode = .undefined,
    callback: ?BufferMapCallback = null,
    userdata_1: ?*anyopaque = null,
    userdata_2: ?*anyopaque = null,
};

pub const CreateComputePipelineAsyncCallbackInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    mode: CallbackMode = .undefined,
    callback: ?CreateComputePipelineAsyncCallback = null,
    userdata_1: ?*anyopaque = null,
    userdata_2: ?*anyopaque = null,
};

pub const CreateRenderPipelineAsyncCallbackInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    mode: CallbackMode = .undefined,
    callback: ?CreateRenderPipelineAsyncCallback = null,
    userdata_1: ?*anyopaque = null,
    userdata_2: ?*anyopaque = null,
};

pub const QueueWorkDoneCallbackInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    mode: CallbackMode = .undefined,
    callback: ?QueueWorkDoneCallback = null,
    userdata_1: ?*anyopaque = null,
    userdata_2: ?*anyopaque = null,
};

pub const PopErrorScopeCallbackInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    mode: CallbackMode = .undefined,
    callback: ?PopErrorScopeCallback = null,
    userdata_1: ?*anyopaque = null,
    userdata_2: ?*anyopaque = null,
};

pub const SupportedFeatures = extern struct {
    feature_count: usize,
    features: ?[*]FeatureName,
};

pub const BindGroupEntry = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    binding: u32,
    buffer: ?Buffer = null,
    offset: u64 = 0,
    size: u64,
    sampler: ?Sampler = null,
    texture_view: ?TextureView = null,
};

pub const BindGroupDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
    layout: BindGroupLayout,
    entry_count: usize,
    entries: ?[*]const BindGroupEntry,
};

pub const BufferBindingLayout = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    binding_type: BufferBindingType = .undefined,
    has_dynamic_offset: c.WGPUBool = c.WGPU_FALSE,
    min_binding_size: u64 = 0,
};

pub const SamplerBindingLayout = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    binding_type: SamplerBindingType = .undefined,
};

pub const TextureBindingLayout = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    sample_type: TextureSampleType = .undefined,
    view_dimension: TextureViewDimension = .undefined,
    multisampled: c.WGPUBool = c.WGPU_FALSE,
};

pub const StorageTextureBindingLayout = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    access: StorageTextureAccess = .undefined,
    format: TextureFormat = .undefined,
    view_dimension: TextureViewDimension = .undefined,
};

pub const BindGroupLayoutEntry = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    binding: u32,
    visibility: ShaderStage,
    binding_array_size: u32 = 0,
    buffer: BufferBindingLayout = .{ .binding_type = .binding_not_used },
    sampler: SamplerBindingLayout = .{ .binding_type = .binding_not_used },
    texture: TextureBindingLayout = .{ .sample_type = .binding_not_used },
    storage_texture: StorageTextureBindingLayout = .{ .access = .binding_not_used },
};

pub const BindGroupLayoutDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
    entry_count: usize,
    entries: ?[*]const BindGroupLayoutEntry,
};

pub const BufferDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
    usage: BufferUsage,
    size: u64,
    mapped_at_creation: c.WGPUBool = c.WGPU_FALSE,
};

pub const CommandEncoderDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
};

pub const ConstantEntry = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    key: c.WGPUStringView,
    value: f64,
};

pub const ComputeState = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    module: ShaderModule,
    entry_point: c.WGPUStringView,
    constant_count: usize = 0,
    constants: ?[*]const ConstantEntry = null,
};

pub const ComputePipelineDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
    layout: ?PipelineLayout = null,
    compute: ComputeState,
};

pub const PipelineLayoutDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
    bind_group_layout_count: usize,
    bind_group_layouts: ?[*]const BindGroupLayout,
    immediate_size: u32 = 0,
};

pub const QuerySetDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
    query_type: QueryType,
    count: u32,
};

pub const RenderBundleEncoderDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
    color_formats_count: usize,
    color_formats: ?[*]const TextureFormat,
    depth_stencil_format: TextureFormat,
    sample_count: u32,
    depth_read_only: c.WGPUBool = c.WGPU_FALSE,
    stencil_read_only: c.WGPUBool = c.WGPU_FALSE,
};

pub const VertexAttribute = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    format: VertexFormat,
    offset: u64,
    shader_location: u32,
};

pub const VertexBufferLayout = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    step_mode: VertexStepMode = .vertex,
    array_stride: u64,
    attribute_count: usize,
    attributes: ?[*]const VertexAttribute = null,
};

pub const VertexState = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    module: ShaderModule,
    entry_point: c.WGPUStringView,
    constant_count: usize = 0,
    constants: ?[*]const ConstantEntry = null,
    buffer_count: usize = 0,
    buffers: ?[*]const VertexBufferLayout = null,
};

pub const BlendComponent = extern struct {
    operation: BlendOperation = .add,
    src_factor: BlendFactor = .one,
    dst_factor: BlendFactor = .zero,
};

pub const BlendState = extern struct {
    color: BlendComponent,
    alpha: BlendComponent,
};

pub const ColorTargetState = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    format: TextureFormat,
    blend: ?*const BlendState = null,
    write_mask: ColorWriteMask = ColorWriteMask.all,
};

pub const FragmentState = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    module: ShaderModule,
    entry_point: c.WGPUStringView,
    constant_count: usize = 0,
    constants: ?[*]const ConstantEntry = null,
    target_count: usize = 0,
    targets: ?[*]const ColorTargetState = null,
};

pub const PrimitiveState = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    topology: PrimitiveTopology = .triangle_list,
    strip_index_format: IndexFormat = .undefined,
    front_face: FrontFace = .ccw,
    cull_mode: CullMode = .none,
    unclipped_depth: c.WGPUBool = c.WGPU_FALSE,
};

pub const StencilFaceState = extern struct {
    compare: CompareFunction = .always,
    fail_op: StencilOperation = .keep,
    depth_fail_op: StencilOperation = .keep,
    pass_op: StencilOperation = .keep,
};

pub const DepthStencilState = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    format: TextureFormat,
    depth_write_enabled: OptionalBool = .undefined,
    depth_compare: CompareFunction = .always,
    stencil_front: StencilFaceState = .{},
    stencil_back: StencilFaceState = .{},
    stencil_read_mask: u32 = 0xffff_ffff,
    stencil_write_mask: u32 = 0xffff_ffff,
    depth_bias: i32 = 0,
    depth_bias_slope_scale: f32 = 0.0,
    depth_bias_clamp: f32 = 0.0,
};

pub const MultisampleState = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    count: u32 = 1,
    mask: u32 = 0xffff_ffff,
    alpha_to_coverage_enabled: c.WGPUBool = c.WGPU_FALSE,
};

pub const RenderPipelineDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
    layout: ?PipelineLayout = null,
    vertex: VertexState,
    primitive: PrimitiveState = .{},
    depth_stencil: ?*const DepthStencilState = null,
    multisample: MultisampleState = .{},
    fragment: ?*const FragmentState = null,
};

pub const SamplerDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
    address_mode_u: AddressMode = .clamp_to_edge,
    address_mode_v: AddressMode = .clamp_to_edge,
    address_mode_w: AddressMode = .clamp_to_edge,
    mag_filter: FilterMode = .nearest,
    min_filter: FilterMode = .nearest,
    mipmap_filter: MipmapFilterMode = .nearest,
    lod_min_clamp: f32 = 0.0,
    lod_max_clamp: f32 = 32.0,
    compare: CompareFunction = .undefined,
    max_anisotropy: u16 = 1,
};

pub const ShaderModuleDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
};

pub const ShaderSourceWGSL = extern struct {
    chain: ChainedStruct,
    code: c.WGPUStringView,
};

pub const SurfaceConfiguration = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    device: Device,
    format: TextureFormat,
    usage: TextureUsage,
    width: u32,
    height: u32,
    view_format_count: usize = 0,
    view_formats: ?[*]TextureFormat = null,
    alpha_mode: CompositeAlphaMode = .auto,
    present_mode: PresentMode = .undefined,
};

pub const SurfaceTexture = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    texture: ?Texture = null,
    status: SurfaceGetCurrentTextureStatus = .success_optimal,
};

pub const Extent3D = extern struct {
    width: u32,
    height: u32 = 1,
    depth_or_array_layers: u32 = 1,
};

pub const TextureDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
    usage: TextureUsage,
    dimension: TextureDimension = .tdim_2d,
    size: Extent3D,
    format: TextureFormat,
    mip_level_count: u32 = 1,
    sample_count: u32 = 1,
    view_format_count: usize = 0,
    view_formats: ?[*]const TextureFormat = null,
};

pub const Limits = extern struct {
    const u32_undefined: u32 = 0xFFFFFFFF;
    const u64_undefined: u64 = 0xFFFFFFFFFFFFFFFF;

    next_in_chain: ?*const ChainedStruct = null,
    max_texture_dimension_1d: u32 = u32_undefined,
    max_texture_dimension_2d: u32 = u32_undefined,
    max_texture_dimension_3d: u32 = u32_undefined,
    max_texture_array_layers: u32 = u32_undefined,
    max_bind_groups: u32 = u32_undefined,
    max_bind_groups_plus_vertex_buffers: u32 = u32_undefined,
    max_bindings_per_bind_group: u32 = u32_undefined,
    max_dynamic_uniform_buffers_per_pipeline_layout: u32 = u32_undefined,
    max_dynamic_storage_buffers_per_pipeline_layout: u32 = u32_undefined,
    max_sampled_textures_per_shader_stage: u32 = u32_undefined,
    max_samplers_per_shader_stage: u32 = u32_undefined,
    max_storage_buffers_per_shader_stage: u32 = u32_undefined,
    max_storage_textures_per_shader_stage: u32 = u32_undefined,
    max_uniform_buffers_per_shader_stage: u32 = u32_undefined,
    max_uniform_buffer_binding_size: u64 = u64_undefined,
    max_storage_buffer_binding_size: u64 = u64_undefined,
    min_uniform_buffer_offset_alignment: u32 = u32_undefined,
    min_storage_buffer_offset_alignment: u32 = u32_undefined,
    max_vertex_buffers: u32 = u32_undefined,
    max_buffer_size: u64 = u64_undefined,
    max_vertex_attributes: u32 = u32_undefined,
    max_vertex_buffer_array_stride: u32 = u32_undefined,
    max_inter_stage_shader_variables: u32 = u32_undefined,
    max_color_attachments: u32 = u32_undefined,
    max_color_attachment_bytes_per_sample: u32 = u32_undefined,
    max_compute_workgroup_storage_size: u32 = u32_undefined,
    max_compute_invocations_per_workgroup: u32 = u32_undefined,
    max_compute_workgroup_size_x: u32 = u32_undefined,
    max_compute_workgroup_size_y: u32 = u32_undefined,
    max_compute_workgroup_size_z: u32 = u32_undefined,
    max_compute_workgroups_per_dimension: u32 = u32_undefined,
    max_immediate_size: u32 = u32_undefined,
};

pub const InstanceLimits = extern struct {
    next_in_chain: ?*ChainedStructOut = null,
    timed_wait_any_max_count: usize,
};

pub const InstanceDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    required_feature_count: usize = 0,
    required_features: ?*const InstanceFeatureName = null,
    required_limits: ?*const InstanceLimits = null,
};

pub const QueueDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
};

pub const DeviceDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
    required_features_count: usize = 0,
    required_features: ?[*]const FeatureName = null,
    required_limits: ?*const Limits = null,
    default_queue: QueueDescriptor = .{},
    device_lost_callback_info: DeviceLostCallbackInfo = .{},
    uncaptured_error_callback_info: UncapturedErrorCallbackInfo = .{},
};

pub const SurfaceDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
};

pub const RequestAdapterOptions = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    feature_level: FeatureLevel = .undefined,
    power_preference: PowerPreference = .undefined,
    force_fallback_adapter: c.WGPUBool = c.WGPU_FALSE,
    backend_type: BackendType = .undefined,
    compatible_surface: ?Surface = null,
};

pub const query_set_index_undefined: u32 = 0xffff_ffff;

pub const PassTimestampWrites = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    query_set: QuerySet,
    beginning_of_pass_write_index: u32 = query_set_index_undefined,
    end_of_pass_write_index: u32 = query_set_index_undefined,
};

pub const ComputePassDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
    timestamp_writes: ?*const PassTimestampWrites = null,
};

pub const Color = extern struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64,
};

pub const RenderPassColorAttachment = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    view: ?TextureView,
    depth_slice: u32 = std.math.maxInt(u32),
    resolve_target: ?TextureView = null,
    load_op: LoadOp,
    store_op: StoreOp,
    clear_value: Color = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 },
};

pub const RenderPassDepthStencilAttachment = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    view: TextureView,
    depth_load_op: LoadOp = .undefined,
    depth_store_op: StoreOp = .undefined,
    depth_clear_value: f32 = 0.0,
    depth_read_only: c.WGPUBool = c.WGPU_FALSE,
    stencil_load_op: LoadOp = .undefined,
    stencil_store_op: StoreOp = .undefined,
    stencil_clear_value: u32 = 0,
    stencil_read_only: c.WGPUBool = c.WGPU_FALSE,
};

pub const RenderPassDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
    color_attachment_count: usize,
    color_attachments: ?[*]const RenderPassColorAttachment,
    depth_stencil_attachment: ?*const RenderPassDepthStencilAttachment = null,
    occlusion_query_set: ?QuerySet = null,
    timestamp_writes: ?*const PassTimestampWrites = null,
};

pub const TexelCopyBufferLayout = extern struct {
    offset: u64 = 0,
    bytes_per_row: u32,
    rows_per_image: u32,
};

pub const Origin3D = extern struct {
    x: u32 = 0,
    y: u32 = 0,
    z: u32 = 0,
};

pub const TexelCopyBufferInfo = extern struct {
    layout: TexelCopyBufferLayout,
    buffer: Buffer,
};

pub const TexelCopyTextureInfo = extern struct {
    texture: Texture,
    mip_level: u32 = 0,
    origin: Origin3D = .{},
    aspect: TextureAspect = .all,
};

pub const CommandBufferDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
};

pub const TextureViewDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
    format: TextureFormat = .undefined,
    dimension: TextureViewDimension = .undefined,
    base_mip_level: u32 = 0,
    mip_level_count: u32 = 0xffff_ffff,
    base_array_layer: u32 = 0,
    array_layer_count: u32 = 0xffff_ffff,
    aspect: TextureAspect = .all,
    usage: TextureUsage = .{},
};

pub const CompilationMessage = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    message: c.WGPUStringView = StringView.initC(),
    message_type: CompilationMessageType,
    line_num: u64,
    line_pos: u64,
    offset: u64,
    length: u64,
};

pub const CompilationInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    message_count: usize,
    messages: ?[*]const CompilationMessage,
};

pub const RenderBundleDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: c.WGPUStringView = StringView.initC(),
};

//
// Section: Callbacks
//

pub const CreateComputePipelineAsyncCallback = *const fn (
    status: CreatePipelineAsyncStatus,
    pipeline: ComputePipeline,
    message: c.WGPUStringView,
    userdata_1: ?*anyopaque,
    userdata_2: ?*anyopaque,
) callconv(.c) void;

pub const CreateRenderPipelineAsyncCallback = *const fn (
    status: CreatePipelineAsyncStatus,
    pipeline: RenderPipeline,
    message: c.WGPUStringView,
    userdata_1: ?*anyopaque,
    userdata_2: ?*anyopaque,
) callconv(.c) void;

pub const PopErrorScopeCallback = *const fn (
    status: PopErrorScopeStatus,
    err_type: ErrorType,
    message: c.WGPUStringView,
    userdata_1: ?*anyopaque,
    userdata_2: ?*anyopaque,
) callconv(.c) void;

pub const DeviceLostCallback = *const fn (
    device: *const Device,
    reason: DeviceLostReason,
    message: c.WGPUStringView,
    userdata_1: ?*anyopaque,
    userdata_2: ?*anyopaque,
) callconv(.c) void;

pub const UncapturedErrorCallback = *const fn (
    device: *const Device,
    err_type: ErrorType,
    message: c.WGPUStringView,
    userdata_1: ?*anyopaque,
    userdata_2: ?*anyopaque,
) callconv(.c) void;

pub const RequestAdapterCallback = *const fn (
    status: RequestAdapterStatus,
    adapter: Adapter,
    message: c.WGPUStringView,
    userdata_1: ?*anyopaque,
    userdata_2: ?*anyopaque,
) callconv(.c) void;

pub const RequestDeviceCallback = *const fn (
    status: RequestDeviceStatus,
    device: Device,
    message: c.WGPUStringView,
    userdata_1: ?*anyopaque,
    userdata_2: ?*anyopaque,
) callconv(.c) void;

pub const BufferMapCallback = *const fn (
    status: MapAsyncStatus,
    message: c.WGPUStringView,
    userdata_1: ?*anyopaque,
    userdata_2: ?*anyopaque,
) callconv(.c) void;

pub const QueueWorkDoneCallback = *const fn (
    status: QueueWorkDoneStatus,
    message: c.WGPUStringView,
    userdata_1: ?*anyopaque,
    userdata_2: ?*anyopaque,
) callconv(.c) void;

pub const CompilationInfoCallback = *const fn (
    status: CompilationInfoRequestStatus,
    info: *const CompilationInfo,
    userdata_1: ?*anyopaque,
    userdata_2: ?*anyopaque,
) callconv(.c) void;

//
// Section: Opaques/Functions
//

pub inline fn createInstance(desc: ?InstanceDescriptor) Instance {
    return @ptrCast(c.wgpuCreateInstance(if (desc) |d| @ptrCast(&d) else null));
}

pub const Instance = *opaque {
    pub fn createSurface(instance: Instance, descriptor: SurfaceDescriptor) Surface {
        return @ptrCast(c.wgpuInstanceCreateSurface(@ptrCast(instance), @ptrCast(&descriptor)));
    }

    pub fn requestAdapter(
        instance: Instance,
        options: RequestAdapterOptions,
        callback_info: RequestAdapterCallbackInfo,
    ) Future {
        return @bitCast(c.wgpuInstanceRequestAdapter(@ptrCast(instance), @ptrCast(&options), @bitCast(callback_info)));
    }

    pub fn waitAny(instance: Instance, futures: []FutureWaitInfo, timeout_ns: u64) WaitStatus {
        return @enumFromInt(c.wgpuInstanceWaitAny(@ptrCast(instance), futures.len, @ptrCast(futures.ptr), timeout_ns));
    }

    pub fn processEvents(instance: Instance) void {
        c.wgpuInstanceProcessEvents(@ptrCast(instance));
    }

    pub fn addRef(instance: Instance) void {
        c.wgpuInstanceAddRef(@ptrCast(instance));
    }

    pub fn release(instance: Instance) void {
        c.wgpuInstanceRelease(@ptrCast(instance));
    }
};

pub const Adapter = *opaque {
    pub fn getFeatures(adapter: Adapter, features: *SupportedFeatures) void {
        c.wgpuAdapterGetFeatures(@ptrCast(adapter), @ptrCast(features));
    }

    pub fn getLimits(adapter: Adapter, limits: *Limits) bool {
        return c.wgpuAdapterGetLimits(@ptrCast(adapter), @ptrCast(limits)) != 0;
    }

    pub fn getInfo(adapter: Adapter, properties: *AdapterInfo) Status {
        return @enumFromInt(c.wgpuAdapterGetInfo(@ptrCast(adapter), @ptrCast(properties)));
    }

    pub fn hasFeature(adapter: Adapter, feature: FeatureName) bool {
        return c.wgpuAdapterHasFeature(@ptrCast(adapter), feature);
    }

    pub fn requestDevice(
        adapter: Adapter,
        descriptor: DeviceDescriptor,
        callback_info: RequestDeviceCallbackInfo,
    ) Future {
        return @bitCast(c.wgpuAdapterRequestDevice(@ptrCast(adapter), @ptrCast(&descriptor), @bitCast(callback_info)));
    }

    pub fn addRef(adapter: Adapter) void {
        c.wgpuAdapterAddRef(@ptrCast(adapter));
    }

    pub fn release(adapter: Adapter) void {
        c.wgpuAdapterRelease(@ptrCast(adapter));
    }
};

pub const Device = *opaque {
    pub fn createBindGroup(device: Device, descriptor: BindGroupDescriptor) BindGroup {
        return @ptrCast(c.wgpuDeviceCreateBindGroup(@ptrCast(device), @ptrCast(&descriptor)));
    }

    pub fn createBindGroupLayout(device: Device, descriptor: BindGroupLayoutDescriptor) BindGroupLayout {
        return @ptrCast(c.wgpuDeviceCreateBindGroupLayout(@ptrCast(device), @ptrCast(&descriptor)));
    }

    pub fn createBuffer(device: Device, descriptor: BufferDescriptor) Buffer {
        return @ptrCast(c.wgpuDeviceCreateBuffer(@ptrCast(device), @ptrCast(&descriptor)));
    }

    pub fn createCommandEncoder(device: Device, descriptor: ?CommandEncoderDescriptor) CommandEncoder {
        return @ptrCast(c.wgpuDeviceCreateCommandEncoder(@ptrCast(device), if (descriptor) |d| @ptrCast(&d) else null));
    }

    pub fn createComputePipeline(device: Device, descriptor: ComputePipelineDescriptor) ComputePipeline {
        return @ptrCast(c.wgpuDeviceCreateComputePipeline(@ptrCast(device), @ptrCast(&descriptor)));
    }

    pub fn createComputePipelineAsync(
        device: Device,
        descriptor: ComputePipelineDescriptor,
        callback_info: CreateComputePipelineAsyncCallbackInfo,
    ) Future {
        return @bitCast(c.wgpuDeviceCreateComputePipelineAsync(
            @ptrCast(device),
            @ptrCast(&descriptor),
            @bitCast(callback_info),
        ));
    }

    pub fn createPipelineLayout(device: Device, descriptor: PipelineLayoutDescriptor) PipelineLayout {
        return @ptrCast(c.wgpuDeviceCreatePipelineLayout(@ptrCast(device), @ptrCast(&descriptor)));
    }

    pub fn createQuerySet(device: Device, descriptor: QuerySetDescriptor) QuerySet {
        return @ptrCast(c.wgpuDeviceCreateQuerySet(@ptrCast(device), @ptrCast(&descriptor)));
    }

    pub fn createRenderBundleEncoder(
        device: Device,
        descriptor: RenderBundleEncoderDescriptor,
    ) RenderBundleEncoder {
        return @ptrCast(c.wgpuDeviceCreateRenderBundleEncoder(@ptrCast(device), @ptrCast(&descriptor)));
    }

    pub fn createRenderPipeline(device: Device, descriptor: RenderPipelineDescriptor) RenderPipeline {
        return @ptrCast(c.wgpuDeviceCreateRenderPipeline(@ptrCast(device), @ptrCast(&descriptor)));
    }

    pub fn createRenderPipelineAsync(
        device: Device,
        descriptor: RenderPipelineDescriptor,
        callback_info: CreateRenderPipelineAsyncCallbackInfo,
    ) Future {
        return @bitCast(c.wgpuDeviceCreateRenderPipelineAsync(
            @ptrCast(device),
            @ptrCast(&descriptor),
            @bitCast(callback_info),
        ));
    }

    pub fn createSampler(device: Device, descriptor: SamplerDescriptor) Sampler {
        return @ptrCast(c.wgpuDeviceCreateSampler(@ptrCast(device), @ptrCast(&descriptor)));
    }

    pub fn createShaderModule(device: Device, descriptor: ShaderModuleDescriptor) ShaderModule {
        return @ptrCast(c.wgpuDeviceCreateShaderModule(@ptrCast(device), @ptrCast(&descriptor)));
    }

    pub fn createTexture(device: Device, descriptor: TextureDescriptor) Texture {
        return @ptrCast(c.wgpuDeviceCreateTexture(@ptrCast(device), @ptrCast(&descriptor)));
    }

    pub fn destroy(device: Device) void {
        c.wgpuDeviceDestroy(@ptrCast(device));
    }

    pub fn getLimits(device: Device, limits: *Limits) bool {
        return c.wgpuDeviceGetLimits(@ptrCast(device), @ptrCast(limits)) != 0;
    }

    pub fn getQueue(device: Device) Queue {
        return @ptrCast(c.wgpuDeviceGetQueue(@ptrCast(device)));
    }

    pub fn hasFeature(device: Device, feature: FeatureName) bool {
        return c.wgpuDeviceHasFeature(@ptrCast(device), feature);
    }

    pub fn popErrorScope(device: Device, callback_info: PopErrorScopeCallbackInfo) Future {
        return @bitCast(c.wgpuDevicePopErrorScope(@ptrCast(device), @bitCast(callback_info)));
    }

    pub fn pushErrorScope(device: Device, filter: ErrorFilter) void {
        c.wgpuDevicePushErrorScope(@ptrCast(device), @intFromEnum(filter));
    }

    pub fn setLabel(device: Device, label: []const u8) void {
        c.wgpuDeviceSetLabel(@ptrCast(device), StringView.cFromZig(label));
    }

    pub fn addRef(device: Device) void {
        c.wgpuDeviceAddRef(@ptrCast(device));
    }

    pub fn release(device: Device) void {
        c.wgpuDeviceRelease(@ptrCast(device));
    }
};

pub const BindGroup = *opaque {
    pub fn setLabel(bind_group: BindGroup, label: []const u8) void {
        c.wgpuBindGroupSetLabel(@ptrCast(bind_group), StringView.cFromZig(label));
    }

    pub fn addRef(bind_group: BindGroup) void {
        c.wgpuBindGroupAddRef(@ptrCast(bind_group));
    }

    pub fn release(bind_group: BindGroup) void {
        c.wgpuBindGroupRelease(@ptrCast(bind_group));
    }
};

pub const BindGroupLayout = *opaque {
    pub fn setLabel(bind_group_layout: BindGroupLayout, label: []const u8) void {
        c.wgpuBindGroupLayoutSetLabel(@ptrCast(bind_group_layout), StringView.cFromZig(label));
    }

    pub fn addRef(bind_group_layout: BindGroupLayout) void {
        c.wgpuBindGroupLayoutAddRef(@ptrCast(bind_group_layout));
    }

    pub fn release(bind_group_layout: BindGroupLayout) void {
        c.wgpuBindGroupLayoutRelease(@ptrCast(bind_group_layout));
    }
};

pub const Buffer = *opaque {
    pub fn destroy(buffer: Buffer) void {
        c.wgpuBufferDestroy(@ptrCast(buffer));
    }

    // `offset` has to be a multiple of 8 (otherwise `null` will be returned).
    // `@sizeOf(T) * len` has to be a multiple of 4 (otherwise `null` will be returned).
    pub fn getConstMappedRange(buffer: Buffer, comptime T: type, offset: usize, len: usize) ?[]const T {
        if (len == 0) return null;
        const ptr = c.wgpuBufferGetConstMappedRange(@ptrCast(buffer), offset, @sizeOf(T) * len);
        if (ptr == null) return null;
        return @as([*]const T, @ptrCast(@alignCast(ptr)))[0..len];
    }

    // `offset` - in bytes, has to be a multiple of 8 (otherwise `null` will be returned).
    // `len` - length of slice to return, in elements of type T, `@sizeOf(T) * len` has to be a multiple of 4 (otherwise `null` will be returned).
    pub fn getMappedRange(buffer: Buffer, comptime T: type, offset: usize, len: usize) ?[]T {
        if (len == 0) return null;
        const ptr = c.wgpuBufferGetMappedRange(@ptrCast(buffer), offset, @sizeOf(T) * len);
        if (ptr == null) return null;
        return @as([*]T, @ptrCast(@alignCast(ptr)))[0..len];
    }

    pub fn getMapState(buffer: Buffer) BufferMapState {
        return c.wgpuBufferGetMapState(@ptrCast(buffer));
    }

    pub fn getSize(buffer: Buffer) usize {
        return @intCast(c.wgpuBufferGetSize(@ptrCast(buffer)));
    }

    pub fn getUsage(buffer: Buffer) BufferUsage {
        return c.wgpuBufferGetUsage(@ptrCast(buffer));
    }

    // `offset` - in bytes, has to be a multiple of 8 (Dawn's validation layer will warn).
    // `size` - size of buffer to map in bytes, has to be a multiple of 4 (Dawn's validation layer will warn).
    pub fn mapAsync(
        buffer: Buffer,
        mode: MapMode,
        offset: usize,
        size: usize,
        callback_info: BufferMapCallbackInfo,
    ) Future {
        return @bitCast(c.wgpuBufferMapAsync(@ptrCast(buffer), @bitCast(mode), offset, size, @bitCast(callback_info)));
    }

    pub fn setLabel(buffer: Buffer, label: []const u8) void {
        c.wgpuBufferSetLabel(@ptrCast(buffer), StringView.cFromZig(label));
    }

    pub fn unmap(buffer: Buffer) void {
        c.wgpuBufferUnmap(@ptrCast(buffer));
    }

    pub fn addRef(buffer: Buffer) void {
        c.wgpuBufferAddRef(@ptrCast(buffer));
    }

    pub fn release(buffer: Buffer) void {
        c.wgpuBufferRelease(@ptrCast(buffer));
    }
};

pub const CommandBuffer = *opaque {
    pub fn setLabel(command_buffer: CommandBuffer, label: []const u8) void {
        c.wgpuCommandBufferSetLabel(command_buffer, StringView.cFromZig(label));
    }

    pub fn addRef(command_buffer: CommandBuffer) void {
        c.wgpuCommandBufferAddRef(command_buffer);
    }

    pub fn release(command_buffer: CommandBuffer) void {
        c.wgpuCommandBufferRelease(@ptrCast(command_buffer));
    }
};

pub const CommandEncoder = *opaque {
    pub fn beginComputePass(
        encoder: CommandEncoder,
        descriptor: ?ComputePassDescriptor,
    ) ComputePassEncoder {
        return @ptrCast(c.wgpuCommandEncoderBeginComputePass(
            @ptrCast(encoder),
            if (descriptor) |d| @ptrCast(&d) else null,
        ));
    }

    pub fn beginRenderPass(
        command_encoder: CommandEncoder,
        descriptor: RenderPassDescriptor,
    ) RenderPassEncoder {
        return @ptrCast(c.wgpuCommandEncoderBeginRenderPass(@ptrCast(command_encoder), @ptrCast(&descriptor)));
    }

    pub fn clearBuffer(command_encoder: CommandEncoder, buffer: Buffer, offset: usize, size: usize) void {
        c.wgpuCommandEncoderClearBuffer(command_encoder, buffer, offset, size);
    }

    pub fn copyBufferToBuffer(
        command_encoder: CommandEncoder,
        source: Buffer,
        source_offset: u64,
        destination: Buffer,
        destination_offset: u64,
        size: u64,
    ) void {
        c.wgpuCommandEncoderCopyBufferToBuffer(
            @ptrCast(command_encoder),
            @ptrCast(source),
            source_offset,
            @ptrCast(destination),
            destination_offset,
            size,
        );
    }

    pub fn copyBufferToTexture(
        command_encoder: CommandEncoder,
        source: TexelCopyBufferInfo,
        destination: TexelCopyTextureInfo,
        copy_size: Extent3D,
    ) void {
        c.wgpuCommandEncoderCopyBufferToTexture(@ptrCast(command_encoder), @ptrCast(&source), @ptrCast(&destination), @ptrCast(&copy_size));
    }

    pub fn copyTextureToBuffer(
        command_encoder: CommandEncoder,
        source: TexelCopyTextureInfo,
        destination: TexelCopyBufferInfo,
        copy_size: Extent3D,
    ) void {
        c.wgpuCommandEncoderCopyTextureToBuffer(@ptrCast(command_encoder), @ptrCast(&source), @ptrCast(&destination), @ptrCast(&copy_size));
    }

    pub fn copyTextureToTexture(
        command_encoder: CommandEncoder,
        source: TexelCopyTextureInfo,
        destination: TexelCopyTextureInfo,
        copy_size: Extent3D,
    ) void {
        c.wgpuCommandEncoderCopyTextureToTexture(
            @ptrCast(command_encoder),
            @ptrCast(&source),
            @ptrCast(&destination),
            @ptrCast(&copy_size),
        );
    }

    pub fn finish(command_encoder: CommandEncoder, descriptor: ?CommandBufferDescriptor) CommandBuffer {
        return @ptrCast(c.wgpuCommandEncoderFinish(
            @ptrCast(command_encoder),
            if (descriptor) |d| @ptrCast(&d) else null,
        ));
    }

    pub fn injectValidationError(command_encoder: CommandEncoder, message: []const u8) void {
        c.wgpuCommandEncoderInjectValidationError(@ptrCast(command_encoder), StringView.cFromZig(message));
    }

    pub fn insertDebugMarker(command_encoder: CommandEncoder, marker_label: []const u8) void {
        c.wgpuCommandEncoderInsertDebugMarker(@ptrCast(command_encoder), StringView.cFromZig(marker_label));
    }

    pub fn popDebugGroup(command_encoder: CommandEncoder) void {
        c.wgpuCommandEncoderPopDebugGroup(@ptrCast(command_encoder));
    }

    pub fn pushDebugGroup(command_encoder: CommandEncoder, group_label: []const u8) void {
        c.wgpuCommandEncoderPushDebugGroup(@ptrCast(command_encoder), StringView.cFromZig(group_label));
    }

    pub fn resolveQuerySet(
        command_encoder: CommandEncoder,
        query_set: QuerySet,
        first_query: u32,
        query_count: u32,
        destination: Buffer,
        destination_offset: u64,
    ) void {
        c.wgpuCommandEncoderResolveQuerySet(
            @ptrCast(command_encoder),
            @ptrCast(query_set),
            first_query,
            query_count,
            @ptrCast(destination),
            destination_offset,
        );
    }

    pub fn setLabel(command_encoder: CommandEncoder, label: []const u8) void {
        c.wgpuCommandEncoderSetLabel(@ptrCast(command_encoder), StringView.cFromZig(label));
    }

    pub fn writeBuffer(
        command_encoder: CommandEncoder,
        buffer: Buffer,
        buffer_offset: u64,
        comptime T: type,
        data: []const T,
    ) void {
        c.wgpuCommandEncoderWriteBuffer(
            command_encoder,
            buffer,
            buffer_offset,
            @as([*]const u8, @ptrCast(data.ptr)),
            @as(u64, @intCast(data.len)) * @sizeOf(T),
        );
    }

    pub fn writeTimestamp(command_encoder: CommandEncoder, query_set: QuerySet, query_index: u32) void {
        c.wgpuCommandEncoderWriteTimestamp(@ptrCast(command_encoder), @ptrCast(query_set), query_index);
    }

    pub fn addRef(command_encoder: CommandEncoder) void {
        c.wgpuCommandEncoderAddRef(command_encoder);
    }

    pub fn release(command_encoder: CommandEncoder) void {
        c.wgpuCommandEncoderRelease(@ptrCast(command_encoder));
    }
};

pub const ComputePassEncoder = *opaque {
    pub fn dispatchWorkgroups(
        compute_pass_encoder: ComputePassEncoder,
        workgroup_count_x: u32,
        workgroup_count_y: u32,
        workgroup_count_z: u32,
    ) void {
        c.wgpuComputePassEncoderDispatchWorkgroups(
            @ptrCast(compute_pass_encoder),
            workgroup_count_x,
            workgroup_count_y,
            workgroup_count_z,
        );
    }

    pub fn dispatchWorkgroupsIndirect(
        compute_pass_encoder: ComputePassEncoder,
        indirect_buffer: Buffer,
        indirect_offset: u64,
    ) void {
        c.wgpuComputePassEncoderDispatchWorkgroupsIndirect(compute_pass_encoder, indirect_buffer, indirect_offset);
    }

    pub fn end(compute_pass_encoder: ComputePassEncoder) void {
        c.wgpuComputePassEncoderEnd(@ptrCast(compute_pass_encoder));
    }

    pub fn insertDebugMarker(compute_pass_encoder: ComputePassEncoder, marker_label: []const u8) void {
        c.wgpuComputePassEncoderInsertDebugMarker(compute_pass_encoder, StringView.cFromZig(marker_label));
    }

    pub fn popDebugGroup(compute_pass_encoder: ComputePassEncoder) void {
        c.wgpuComputePassEncoderPopDebugGroup(compute_pass_encoder);
    }

    pub fn pushDebugGroup(compute_pass_encoder: ComputePassEncoder, group_label: []const u8) void {
        c.wgpuComputePassEncoderPushDebugGroup(compute_pass_encoder, StringView.cFromZig(group_label));
    }

    pub fn setBindGroup(
        compute_pass_encoder: ComputePassEncoder,
        group_index: u32,
        bind_group: BindGroup,
        dynamic_offsets: ?[]const u32,
    ) void {
        c.wgpuComputePassEncoderSetBindGroup(
            @ptrCast(compute_pass_encoder),
            group_index,
            @ptrCast(bind_group),
            if (dynamic_offsets) |dynoff| @as(u32, @intCast(dynoff.len)) else 0,
            if (dynamic_offsets) |dynoff| dynoff.ptr else null,
        );
    }

    pub fn setLabel(compute_pass_encoder: ComputePassEncoder, label: []const u8) void {
        c.wgpuComputePassEncoderSetLabel(@ptrCast(compute_pass_encoder), StringView.cFromZig(label));
    }

    pub fn setPipeline(compute_pass_encoder: ComputePassEncoder, pipeline: ComputePipeline) void {
        c.wgpuComputePassEncoderSetPipeline(@ptrCast(compute_pass_encoder), @ptrCast(pipeline));
    }

    pub fn writeTimestamp(
        compute_pass_encoder: ComputePassEncoder,
        query_set: QuerySet,
        query_index: u32,
    ) void {
        c.wgpuComputePassEncoderWriteTimestamp(compute_pass_encoder, query_set, query_index);
    }

    pub fn addRef(compute_pass_encoder: ComputePassEncoder) void {
        c.wgpuComputePassEncoderAddRef(compute_pass_encoder);
    }

    pub fn release(compute_pass_encoder: ComputePassEncoder) void {
        c.wgpuComputePassEncoderRelease(@ptrCast(compute_pass_encoder));
    }
};

pub const ComputePipeline = *opaque {
    pub fn getBindGroupLayout(compute_pipeline: ComputePipeline, group_index: u32) BindGroupLayout {
        return c.wgpuComputePipelineGetBindGroupLayout(compute_pipeline, group_index);
    }

    pub fn setLabel(compute_pipeline: ComputePipeline, label: []const u8) void {
        c.wgpuComputePipelineSetLabel(compute_pipeline, StringView.cFromZig(label));
    }

    pub fn addRef(compute_pipeline: ComputePipeline) void {
        c.wgpuComputePipelineAddRef(compute_pipeline);
    }

    pub fn release(compute_pipeline: ComputePipeline) void {
        c.wgpuComputePipelineRelease(@ptrCast(compute_pipeline));
    }
};

pub const ExternalTexture = *opaque {
    pub fn destroy(external_texture: ExternalTexture) void {
        c.wgpuExternalTextureDestroy(external_texture);
    }

    pub fn setLabel(external_texture: ExternalTexture, label: []const u8) void {
        c.wgpuExternalTextureSetLabel(external_texture, StringView.cFromZig(label));
    }

    pub fn addRef(external_texture: ExternalTexture) void {
        c.wgpuExternalTextureAddRef(external_texture);
    }

    pub fn release(external_texture: ExternalTexture) void {
        c.wgpuExternalTextureRelease(external_texture);
    }
};

pub const PipelineLayout = *opaque {
    pub fn setLabel(pipeline_layout: PipelineLayout, label: []const u8) void {
        c.wgpuPipelineLayoutSetLabel(pipeline_layout, StringView.cFromZig(label));
    }

    pub fn addRef(pipeline_layout: PipelineLayout) void {
        c.wgpuPipelineLayoutAddRef(pipeline_layout);
    }

    pub fn release(pipeline_layout: PipelineLayout) void {
        c.wgpuPipelineLayoutRelease(@ptrCast(pipeline_layout));
    }
};

pub const QuerySet = *opaque {
    pub fn destroy(query_set: QuerySet) void {
        c.wgpuQuerySetDestroy(query_set);
    }

    pub fn setLabel(query_set: QuerySet, label: []const u8) void {
        c.wgpuQuerySetSetLabel(query_set, StringView.cFromZig(label));
    }

    pub fn addRef(query_set: QuerySet) void {
        c.wgpuQuerySetAddRef(query_set);
    }

    pub fn release(query_set: QuerySet) void {
        c.wgpuQuerySetRelease(@ptrCast(query_set));
    }
};

pub const Queue = *opaque {

    pub fn onSubmittedWorkDone(
        queue: Queue,
        callback_info: QueueWorkDoneCallbackInfo,
    ) Future {
        return @bitCast(c.wgpuQueueOnSubmittedWorkDone(@ptrCast(queue), @bitCast(callback_info)));
    }

    pub fn setLabel(queue: Queue, label: []const u8) void {
        c.wgpuQueueSetLabel(queue, StringView.cFromZig(label));
    }

    pub fn submit(queue: Queue, commands: []const CommandBuffer) void {
        c.wgpuQueueSubmit(
            @ptrCast(queue),
            commands.len,
            @ptrCast(commands.ptr),
        );
    }

    pub fn writeBuffer(
        queue: Queue,
        buffer: Buffer,
        buffer_offset: usize,
        comptime T: type,
        data: []const T,
    ) void {
        c.wgpuQueueWriteBuffer(
            @ptrCast(queue),
            @ptrCast(buffer),
            @intCast(buffer_offset),
            @as(*const anyopaque, @ptrCast(data.ptr)),
            data.len * @sizeOf(T),
        );
    }

    pub fn writeTexture(
        queue: Queue,
        destination: TexelCopyTextureInfo,
        data_layout: TexelCopyBufferLayout,
        write_size: Extent3D,
        comptime T: type,
        data: []const T,
    ) void {
        c.wgpuQueueWriteTexture(
            @ptrCast(queue),
            @ptrCast(&destination),
            @as(*const anyopaque, @ptrCast(data.ptr)),
            data.len * @sizeOf(T),
            @ptrCast(&data_layout),
            @ptrCast(&write_size),
        );
    }

    pub fn addRef(queue: Queue) void {
        c.wgpuQueueAddRef(@ptrCast(queue));
    }

    pub fn release(queue: Queue) void {
        c.wgpuQueueRelease(@ptrCast(queue));
    }
};

pub const RenderBundle = *opaque {
    pub fn addRef(render_bundle: RenderBundle) void {
        c.wgpuRenderBundleAddRef(render_bundle);
    }

    pub fn release(render_bundle: RenderBundle) void {
        c.wgpuRenderBundleRelease(render_bundle);
    }
};

pub const RenderBundleEncoder = *opaque {
    pub fn draw(
        render_bundle_encoder: RenderBundleEncoder,
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
    ) void {
        c.wgpuRenderBundleEncoderDraw(
            render_bundle_encoder,
            vertex_count,
            instance_count,
            first_vertex,
            first_instance,
        );
    }

    pub fn drawIndexed(
        render_bundle_encoder: RenderBundleEncoder,
        index_count: u32,
        instance_count: u32,
        first_index: u32,
        base_vertex: i32,
        first_instance: u32,
    ) void {
        c.wgpuRenderBundleEncoderDrawIndexed(
            render_bundle_encoder,
            index_count,
            instance_count,
            first_index,
            base_vertex,
            first_instance,
        );
    }

    pub fn drawIndexedIndirect(
        render_bundle_encoder: RenderBundleEncoder,
        indirect_buffer: Buffer,
        indirect_offset: u64,
    ) void {
        c.wgpuRenderBundleEncoderDrawIndexedIndirect(render_bundle_encoder, indirect_buffer, indirect_offset);
    }

    pub fn drawIndirect(
        render_bundle_encoder: RenderBundleEncoder,
        indirect_buffer: Buffer,
        indirect_offset: u64,
    ) void {
        c.wgpuRenderBundleEncoderDrawIndirect(render_bundle_encoder, indirect_buffer, indirect_offset);
    }

    pub fn finish(
        render_bundle_encoder: RenderBundleEncoder,
        descriptor: RenderBundleDescriptor,
    ) RenderBundle {
        return c.wgpuRenderBundleEncoderFinish(render_bundle_encoder, &descriptor);
    }

    pub fn insertDebugMarker(
        render_bundle_encoder: RenderBundleEncoder,
        marker_label: []const u8,
    ) void {
        c.wgpuRenderBundleEncoderInsertDebugMarker(render_bundle_encoder, StringView.cFromZig(marker_label));
    }

    pub fn popDebugGroup(render_bundle_encoder: RenderBundleEncoder) void {
        c.wgpuRenderBundleEncoderPopDebugGroup(render_bundle_encoder);
    }

    pub fn pushDebugGroup(render_bundle_encoder: RenderBundleEncoder, group_label: []const u8) void {
        c.wgpuRenderBundleEncoderPushDebugGroup(render_bundle_encoder, StringView.cFromZig(group_label));
    }

    pub fn setBindGroup(
        render_bundle_encoder: RenderBundleEncoder,
        group_index: u32,
        group: BindGroup,
        dynamic_offsets: ?[]const u32,
    ) void {
        c.wgpuRenderBundleEncoderSetBindGroup(
            render_bundle_encoder,
            group_index,
            group,
            if (dynamic_offsets) |dynoff| @as(u32, @intCast(dynoff.len)) else 0,
            if (dynamic_offsets) |dynoff| dynoff.ptr else null,
        );
    }

    pub fn setIndexBuffer(
        render_bundle_encoder: RenderBundleEncoder,
        buffer: Buffer,
        format: IndexFormat,
        offset: u64,
        size: u64,
    ) void {
        c.wgpuRenderBundleEncoderSetIndexBuffer(render_bundle_encoder, buffer, format, offset, size);
    }

    pub fn setLabel(render_bundle_encoder: RenderBundleEncoder, label: []const u8) void {
        c.wgpuRenderBundleEncoderSetLabel(render_bundle_encoder, StringView.cFromZig(label));
    }

    pub fn setPipeline(render_bundle_encoder: RenderBundleEncoder, pipeline: RenderPipeline) void {
        c.wgpuRenderBundleEncoderSetPipeline(render_bundle_encoder, pipeline);
    }

    pub fn setVertexBuffer(
        render_bundle_encoder: RenderBundleEncoder,
        slot: u32,
        buffer: Buffer,
        offset: u64,
        size: u64,
    ) void {
        c.wgpuRenderBundleEncoderSetVertexBuffer(render_bundle_encoder, slot, buffer, offset, size);
    }

    pub fn addRef(render_bundle_encoder: RenderBundleEncoder) void {
        c.wgpuRenderBundleEncoderAddRef(render_bundle_encoder);
    }

    pub fn release(render_bundle_encoder: RenderBundleEncoder) void {
        c.wgpuRenderBundleEncoderRelease(render_bundle_encoder);
    }
};

pub const RenderPassEncoder = *opaque {
    pub fn beginOcclusionQuery(render_pass_encoder: RenderPassEncoder, query_index: u32) void {
        c.wgpuRenderPassEncoderBeginOcclusionQuery(render_pass_encoder, query_index);
    }

    pub fn draw(
        render_pass_encoder: RenderPassEncoder,
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
    ) void {
        c.wgpuRenderPassEncoderDraw(
            @ptrCast(render_pass_encoder),
            vertex_count,
            instance_count,
            first_vertex,
            first_instance,
        );
    }

    pub fn drawIndexed(
        render_pass_encoder: RenderPassEncoder,
        index_count: u32,
        instance_count: u32,
        first_index: u32,
        base_vertex: i32,
        first_instance: u32,
    ) void {
        c.wgpuRenderPassEncoderDrawIndexed(
            @ptrCast(render_pass_encoder),
            index_count,
            instance_count,
            first_index,
            base_vertex,
            first_instance,
        );
    }

    pub fn drawIndexedIndirect(
        render_pass_encoder: RenderPassEncoder,
        indirect_buffer: Buffer,
        indirect_offset: u64,
    ) void {
        c.wgpuRenderPassEncoderDrawIndexedIndirect(render_pass_encoder, indirect_buffer, indirect_offset);
    }

    pub fn drawIndirect(
        render_pass_encoder: RenderPassEncoder,
        indirect_buffer: Buffer,
        indirect_offset: u64,
    ) void {
        c.wgpuRenderPassEncoderDrawIndirect(render_pass_encoder, indirect_buffer, indirect_offset);
    }

    pub fn end(render_pass_encoder: RenderPassEncoder) void {
        c.wgpuRenderPassEncoderEnd(@ptrCast(render_pass_encoder));
    }

    pub fn endOcclusionQuery(render_pass_encoder: RenderPassEncoder) void {
        c.wgpuRenderPassEncoderEndOcclusionQuery(render_pass_encoder);
    }

    pub fn executeBundles(
        render_pass_encoder: RenderPassEncoder,
        bundle_count: u32,
        bundles: [*]const RenderBundle,
    ) void {
        c.wgpuRenderPassEncoderExecuteBundles(render_pass_encoder, bundle_count, bundles);
    }

    pub fn insertDebugMarker(render_pass_encoder: RenderPassEncoder, marker_label: []const u8) void {
        c.wgpuRenderPassEncoderInsertDebugMarker(render_pass_encoder, StringView.cFromZig(marker_label));
    }

    pub fn popDebugGroup(render_pass_encoder: RenderPassEncoder) void {
        c.wgpuRenderPassEncoderPopDebugGroup(render_pass_encoder);
    }

    pub fn pushDebugGroup(render_pass_encoder: RenderPassEncoder, group_label: []const u8) void {
        c.wgpuRenderPassEncoderPushDebugGroup(render_pass_encoder, StringView.cFromZig(group_label));
    }

    pub fn setBindGroup(
        render_pass_encoder: RenderPassEncoder,
        group_index: u32,
        group: BindGroup,
        dynamic_offsets: ?[]const u32,
    ) void {
        c.wgpuRenderPassEncoderSetBindGroup(
            @ptrCast(render_pass_encoder),
            group_index,
            @ptrCast(group),
            if (dynamic_offsets) |dynoff| dynoff.len else 0,
            if (dynamic_offsets) |dynoff| dynoff.ptr else null,
        );
    }

    pub fn setBlendConstant(render_pass_encoder: RenderPassEncoder, color: Color) void {
        c.wgpuRenderPassEncoderSetBlendConstant(render_pass_encoder, &color);
    }

    pub fn setIndexBuffer(
        render_pass_encoder: RenderPassEncoder,
        buffer: Buffer,
        format: IndexFormat,
        offset: u64,
        size: u64,
    ) void {
        c.wgpuRenderPassEncoderSetIndexBuffer(@ptrCast(render_pass_encoder), @ptrCast(buffer), @intFromEnum(format), offset, size);
    }

    pub fn setLabel(render_pass_encoder: RenderPassEncoder, label: []const u8) void {
        c.wgpuRenderPassEncoderSetLabel(@ptrCast(render_pass_encoder), StringView.cFromZig(label));
    }

    pub fn setPipeline(render_pass_encoder: RenderPassEncoder, pipeline: RenderPipeline) void {
        c.wgpuRenderPassEncoderSetPipeline(@ptrCast(render_pass_encoder), @ptrCast(pipeline));
    }

    pub fn setScissorRect(
        render_pass_encoder: RenderPassEncoder,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    ) void {
        c.wgpuRenderPassEncoderSetScissorRect(render_pass_encoder, x, y, width, height);
    }

    pub fn setStencilReference(render_pass_encoder: RenderPassEncoder, ref: u32) void {
        c.wgpuRenderPassEncoderSetStencilReference(render_pass_encoder, ref);
    }

    pub fn setVertexBuffer(
        render_pass_encoder: RenderPassEncoder,
        slot: u32,
        buffer: Buffer,
        offset: u64,
        size: u64,
    ) void {
        c.wgpuRenderPassEncoderSetVertexBuffer(@ptrCast(render_pass_encoder), slot, @ptrCast(buffer), offset, size);
    }

    pub fn setViewport(
        render_pass_encoder: RenderPassEncoder,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        min_depth: f32,
        max_depth: f32,
    ) void {
        c.wgpuRenderPassEncoderSetViewport(render_pass_encoder, x, y, width, height, min_depth, max_depth);
    }

    pub fn writeTimestamp(
        render_pass_encoder: RenderPassEncoder,
        query_set: QuerySet,
        query_index: u32,
    ) void {
        c.wgpuRenderPassEncoderWriteTimestamp(render_pass_encoder, query_set, query_index);
    }

    pub fn addRef(render_pass_encoder: RenderPassEncoder) void {
        c.wgpuRenderPassEncoderAddRef(render_pass_encoder);
    }

    pub fn release(render_pass_encoder: RenderPassEncoder) void {
        c.wgpuRenderPassEncoderRelease(@ptrCast(render_pass_encoder));
    }
};

pub const RenderPipeline = *opaque {
    pub fn getBindGroupLayout(render_pipeline: RenderPipeline, group_index: u32) BindGroupLayout {
        return c.wgpuRenderPipelineGetBindGroupLayout(@ptrCast(render_pipeline), group_index);
    }

    pub fn setLabel(render_pipeline: RenderPipeline, label: []const u8) void {
        c.wgpuRenderPipelineSetLabel(@ptrCast(render_pipeline), StringView.cFromZig(label));
    }

    pub fn addRef(render_pipeline: RenderPipeline) void {
        c.wgpuRenderPipelineAddRef(@ptrCast(render_pipeline));
    }

    pub fn release(render_pipeline: RenderPipeline) void {
        c.wgpuRenderPipelineRelease(@ptrCast(render_pipeline));
    }
};

pub const Sampler = *opaque {
    pub fn setLabel(sampler: Sampler, label: []const u8) void {
        c.wgpuSamplerSetLabel(@ptrCast(sampler), StringView.cFromZig(label));
    }

    pub fn addRef(sampler: Sampler) void {
        c.wgpuSamplerAddRef(@ptrCast(sampler));
    }

    pub fn release(sampler: Sampler) void {
        c.wgpuSamplerRelease(@ptrCast(sampler));
    }
};

pub const ShaderModule = *opaque {
    pub fn getCompilationInfo(
        shader_module: ShaderModule,
        callback: CompilationInfoCallback,
        userdata: ?*anyopaque,
    ) void {
        c.wgpuShaderModuleGetCompilationInfo(@ptrCast(shader_module), callback, userdata);
    }

    pub fn setLabel(shader_module: ShaderModule, label: []const u8) void {
        c.wgpuShaderModuleSetLabel(@ptrCast(shader_module), StringView.cFromZig(label));
    }

    pub fn addRef(shader_module: ShaderModule) void {
        c.wgpuShaderModuleAddRef(@ptrCast(shader_module));
    }

    pub fn release(shader_module: ShaderModule) void {
        c.wgpuShaderModuleRelease(@ptrCast(shader_module));
    }
};

pub const Surface = *opaque {
    pub fn configure(
        surface: Surface,
        config: SurfaceConfiguration,
    ) void {
        c.wgpuSurfaceConfigure(@ptrCast(surface), @ptrCast(&config));
    }

    pub fn getCurrentTexture(surface: Surface, surface_texture: *SurfaceTexture) void {
        c.wgpuSurfaceGetCurrentTexture(@ptrCast(surface), @ptrCast(surface_texture));
    }

    pub fn present(surface: Surface) Status {
        return @enumFromInt(c.wgpuSurfacePresent(@ptrCast(surface)));
    }

    pub fn addRef(surface: Surface) void {
        c.wgpuSurfaceAddRef(@ptrCast(surface));
    }

    pub fn release(surface: Surface) void {
        c.wgpuSurfaceRelease(@ptrCast(surface));
    }
};

pub const Texture = *opaque {
    pub fn createView(texture: Texture, descriptor: TextureViewDescriptor) TextureView {
        return @ptrCast(c.wgpuTextureCreateView(@ptrCast(texture), @ptrCast(&descriptor)));
    }

    pub fn destroy(texture: Texture) void {
        c.wgpuTextureDestroy(@ptrCast(texture));
    }

    pub fn setLabel(texture: Texture, label: []const u8) void {
        c.wgpuTextureSetLabel(@ptrCast(texture), StringView.cFromZig(label));
    }

    pub fn getWidth(texture: Texture) u32 {
        return c.wgpuTextureGetWidth(@ptrCast(texture));
    }

    pub fn getHeight(texture: Texture) u32 {
        return c.wgpuTextureGetHeight(@ptrCast(texture));
    }

    pub fn addRef(texture: Texture) void {
        c.wgpuTextureAddRef(@ptrCast(texture));
    }

    pub fn release(texture: Texture) void {
        c.wgpuTextureRelease(@ptrCast(texture));
    }
};

pub const TextureView = *opaque {
    pub fn setLabel(texture_view: TextureView, label: []const u8) void {
        c.wgpuTextureViewSetLabel(@ptrCast(texture_view), StringView.cFromZig(label));
    }

    pub fn addRef(texture_view: TextureView) void {
        c.wgpuTextureViewAddRef(@ptrCast(texture_view));
    }

    pub fn release(texture_view: TextureView) void {
        c.wgpuTextureViewRelease(@ptrCast(texture_view));
    }
};

//
// Section: Tests
//

const c_prefix = "WGPU";
const max_supported_enum_name_len = 128;

test "extern_struct_abi_compatibility" {
    @setEvalBranchQuota(10_000);
    // To see all output, set std.testing.log_level = std.log.Level.debug;

    slog.info("checking struct ABI compatibility...", .{});
    inline for (comptime std.meta.declarations(@This())) |decl| {
        const ZigStruct = @field(@This(), decl.name);
        if (@TypeOf(ZigStruct) != type) continue;
        if (comptime std.meta.activeTag(@typeInfo(ZigStruct)) != .@"struct") continue;
        if (@typeInfo(ZigStruct).@"struct".layout != .@"extern") continue;
        if (@hasDecl(ZigStruct, "_skip_abi_compat")) continue;
        const c_name = c_prefix ++ decl.name;

        // Existence check - if the zig source still declares a struct that no longer
        // exists in the C header, the tests will fail to compile
        const CStruct = comptime blk: {
            if (!@hasDecl(c, c_name)) {
                @compileError("Missing C struct " ++ c_name ++ " to match " ++ decl.name ++
                    ". Declare a const _skip_abi_compat inside " ++ decl.name ++ " to exclude.");
            } else break :blk @field(c, c_name);
        };

        // Size check
        std.testing.expectEqual(@sizeOf(CStruct), @sizeOf(ZigStruct)) catch |err| {
            slog.err("@sizeOf({s}) != @sizeOf({s})", .{ c_name, decl.name });
            return err;
        };

        // Field‑count check
        const zig_fields = std.meta.fields(ZigStruct);
        const c_fields = std.meta.fields(CStruct);
        if (c_fields.len != zig_fields.len) {
            slog.err(
                "Field count mismatch: C `{s}` has {d} fields, Zig `{s}` has {d}",
                .{ c_name, c_fields.len, decl.name, zig_fields.len },
            );
            continue;
        }

        const limit = @min(c_fields.len, zig_fields.len);
        // Offset checks
        inline for (0..limit) |i| {
            const zig_f = zig_fields[i];
            const c_f = c_fields[i];
            std.testing.expectEqual(
                @offsetOf(CStruct, c_f.name),
                @offsetOf(ZigStruct, zig_f.name),
            ) catch |err| {
                slog.err(
                    "Offset mismatch at index {d}: C.{s} vs Zig.{s}",
                    .{ i, c_f.name, zig_f.name },
                );
                return err;
            };
        }

        slog.debug("\tchecked {s} == {s}", .{ c_name, decl.name });
    }
}

test "enum_abi_compatibility" {
    @setEvalBranchQuota(100_000_000);
    // To see all output, set std.testing.log_level = std.log.Level.debug;

    slog.info("checking enum ABI compatibility...", .{});
    const c_import_decls = comptime blk: {
        break :blk std.meta.declarations(c);
    };

    inline for (comptime std.meta.declarations(@This())) |decl| {
        const ZigEnum = @field(@This(), decl.name);
        if (@TypeOf(ZigEnum) != type) continue;
        if (comptime std.meta.activeTag(@typeInfo(ZigEnum)) != .@"enum") continue;

        const c_name = c_prefix ++ decl.name;
        const c_e_name = "enum_" ++ c_name;
        if (!@hasDecl(c, c_e_name)) {
            @compileError("Missing C enum " ++ c_name ++ " to match " ++ decl.name);
        }

        const zig_fields = std.meta.fields(ZigEnum);
        // Build the list of (name, value) pairs straight from the @cImport
        // declarations instead of constructing a C enum type: Zig 0.16 removed
        // the @Type builtin, and we only need the field list for comparison.
        const c_fields = comptime blk: {
            var fields: [c_import_decls.len]std.builtin.Type.EnumField = undefined;
            var n: usize = 0;
            for (c_import_decls) |c_decl| {
                if (!std.mem.startsWith(u8, c_decl.name, c_name ++ "_")) continue;
                const c_field = @field(c, c_decl.name);
                if (std.meta.activeTag(@typeInfo(@TypeOf(c_field))) != .int) continue;
                fields[n] = .{
                    .name = c_decl.name,
                    .value = c_field,
                };
                n += 1;
            }
            break :blk fields[0..n];
        };

        inline for (c_fields) |c_field| {
            const short_name = comptime blk: {
                var str_buf: [max_supported_enum_name_len]u8 = undefined;
                const normalized = normalizeCEnumField(c_field.name, str_buf[0..]);
                break :blk std.fmt.comptimePrint("{s}", .{normalized});
            };

            if (std.meta.fieldIndex(ZigEnum, short_name)) |i| {
                const zig_field = zig_fields[i];
                const zig_val = @intFromEnum(@field(ZigEnum, zig_field.name));
                if (zig_val != c_field.value) {
                    slog.err(
                        "enum value mismatch: {s} == {}, but {s}.{s} == {}",
                        .{ c_field.name, c_field.value, decl.name, short_name, zig_val },
                    );
                    return error.EnumValueMismatch;
                }
            } else {
                if (!std.mem.endsWith(u8, c_field.name, "Force32")) {
                    slog.warn("missing Zig enum field for {s} (expected {s}.{s})", .{
                        c_field.name, decl.name, short_name,
                    });

                    // slog.err("missing Zig enum field for {s} (expected {s}.{s})", .{
                    //     c_field.name, decl.name, short_name,
                    // });
                    // return error.EnumFieldMissing;
                }
            }

            slog.debug("\tchecked {s} == {s}.{s}", .{ c_field.name, decl.name, short_name });
        }
    }
}

test "wgpu_ref_all_decls" {
    std.testing.refAllDecls(@This());
}

fn normalizeCEnumField(full_field_name: []const u8, buf: []u8) []const u8 {
    // e.g., for WGPUCreatePipelineAsyncStatus_CallbackCancelled:
    // strip prefix "WGPUCreatePipelineAsyncStatus_" -> "CallbackCancelled"
    // convert to snake_case -> "callback_cancelled"

    if (hardcodedNameReplacement(full_field_name)) |replacement| return replacement;
    const idx = std.mem.indexOf(u8, full_field_name, "_") orelse return full_field_name;
    const suffix = full_field_name[(idx + 1)..];
    if (hardcodedSuffixReplacement(suffix)) |replacement| return replacement;

    var out_i: usize = 0;
    var prev: u8 = 0;
    for (suffix, 0..) |chr, i| {
        const maybe_next: ?u8 = if (suffix.len > i + 1) suffix[i + 1] else null;
        var underscore = false;

        if (i > 0 and std.ascii.isUpper(chr)) {
            if (std.ascii.isLower(prev) or std.ascii.isDigit(prev)) underscore = true;
            if (maybe_next) |next| {
                if (std.ascii.isUpper(prev) and std.ascii.isLower(next)) underscore = true;
            }
        }

        if (underscore) {
            buf[out_i] = '_';
            out_i += 1;
        }
        buf[out_i] = std.ascii.toLower(chr);
        out_i += 1;
        prev = chr;
    }
    return buf[0..out_i];
}

fn hardcodedNameReplacement(orig: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, orig, "WGPUTextureDimension_1D")) return "tdim_1d";
    if (std.mem.eql(u8, orig, "WGPUTextureDimension_2D")) return "tdim_2d";
    if (std.mem.eql(u8, orig, "WGPUTextureDimension_3D")) return "tdim_3d";
    if (std.mem.eql(u8, orig, "WGPUTextureViewDimension_1D")) return "tvdim_1d";
    if (std.mem.eql(u8, orig, "WGPUTextureViewDimension_2D")) return "tvdim_2d";
    if (std.mem.eql(u8, orig, "WGPUTextureViewDimension_2DArray")) return "tvdim_2d_array";
    if (std.mem.eql(u8, orig, "WGPUTextureViewDimension_Cube")) return "tvdim_cube";
    if (std.mem.eql(u8, orig, "WGPUTextureViewDimension_CubeArray")) return "tvdim_cube_array";
    if (std.mem.eql(u8, orig, "WGPUTextureViewDimension_3D")) return "tvdim_3d";
    if (std.mem.eql(u8, orig, "WGPUFeatureName_TextureCompressionBCSliced3D")) return "texture_compression_bc_sliced_3d";
    if (std.mem.eql(u8, orig, "WGPUFeatureName_TextureCompressionASTCSliced3D")) return "texture_compression_astc_sliced_3d";
    if (std.mem.eql(u8, orig, "WGPUSType_RequestAdapterWebXROptions")) return "request_adapter_webxr_options";
    return null;
}

fn hardcodedSuffixReplacement(suffix: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, suffix, "WebGPU")) return "webgpu";
    if (std.mem.eql(u8, suffix, "OpenGL")) return "opengl";
    if (std.mem.eql(u8, suffix, "OpenGLES")) return "opengles";
    if (std.mem.eql(u8, suffix, "D3D11")) return "d3d11";
    if (std.mem.eql(u8, suffix, "D3D12")) return "d3d12";
    return null;
}
