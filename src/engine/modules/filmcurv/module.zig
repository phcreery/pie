const api = @import("../api.zig");

pub const def: api.ModuleDef = .{
    .desc = @import("module.zon"),
    .initParams = initParams,
    .createNodes = createNodes,
};

pub fn initParams(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    try api.initParamNamed(pipe, mod, "brightness", @as(f32, 2.22));
    try api.initParamNamed(pipe, mod, "contrast", @as(f32, 1.0));
    try api.initParamNamed(pipe, mod, "bias", @as(f32, 0.0));
    try api.initParamNamed(pipe, mod, "colormode", @as(i32, 0));
}

pub fn createNodes(pipe: api.PipelineHandle, mod: api.ModuleHandle) !void {
    const mod_output_sock = try api.getModSocket(pipe, mod, "output");
    const node_filmcurv = try api.addNode(pipe, mod, @import("node.filmcurv.zon"));
    try api.setNodeRunSize(pipe, node_filmcurv, mod_output_sock.roi.?);
    try api.inheritSocket(pipe, mod, "input", node_filmcurv, "input");
    try api.inheritSocket(pipe, mod, "output", node_filmcurv, "output");
}
