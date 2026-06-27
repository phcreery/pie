const std = @import("std");

/// Get the type that specifies a coordinate for a SPIR-V image or sampled image.
/// The `Element` type usually depends on the context.
/// The result is either a scalar or a vector `Element` where each dimension is in order (and followed by the array index if the image type is arrayed).
pub fn ImageCoordinate(
    comptime Image: type,
    comptime Element: type,
) type {
    const image_info = switch (@typeInfo(Image)) {
        .spirv => |spirv| switch (spirv) {
            .sampled_image => |sampled_image| @typeInfo(sampled_image).spirv.image,
            .image => |image| image,
            else => @compileError("Expected SPIR-V image or sampled image type, found '" ++ @typeName(Image) ++ "'"),
        },
        else => @compileError("Expected SPIR-V image or sampled image type, found '" ++ @typeName(Image) ++ "'"),
    };
    const array_coordinate_addition = if (image_info.arrayed) 1 else 0;
    const dim = switch (image_info.dim) {
        .@"1d" => 1 + array_coordinate_addition,
        .@"2d", .cube => 2 + array_coordinate_addition,
        .@"3d" => 3 + array_coordinate_addition,
    };
    if (dim == 1) return Element else return @Vector(dim, Element);
}

/// The type of the components that result from sampling or reading from the given SPIR-V image or sampled image type.
pub fn ImageSampledType(
    comptime Image: type,
) type {
    const image_info = switch (@typeInfo(Image)) {
        .spirv => |spirv| switch (spirv) {
            .sampled_image => |sampled_image| @typeInfo(sampled_image).spirv.image,
            .image => |image| image,
            else => @compileError("Expected SPIR-V image or sampled image type, found '" ++ @typeName(Image) ++ "'"),
        },
        else => @compileError("Expected SPIR-V image or sampled image type, found '" ++ @typeName(Image) ++ "'"),
    };
    return switch (image_info.usage) {
        .unknown => |unknown| unknown,
        .sampled => |sampled| sampled,
        .storage => u32, // TODO: Fix when other child types are allowed.
    };
}

/// Operands that may optionally be specified when sampling with an implicit level of detail.
pub const ImageSampleImplicitLodOperands = struct {
    bias: f32 = 0,
    // TODO: Add more operands.
};

/// The type of `sampled_image` must be a pointer to a SPIR-V sampled image.
pub fn imageSampleImplicitLod(
    sampled_image: anytype,
    coordinate: ImageCoordinate(std.meta.Child(@TypeOf(sampled_image)), f32),
    operands: ImageSampleImplicitLodOperands,
) @Vector(4, ImageSampledType(std.meta.Child(@TypeOf(sampled_image)))) {
    _ = operands; // TODO: Support operands.

    const SampledImage = switch (@typeInfo(@TypeOf(sampled_image))) {
        .pointer => |pointer| pointer.child,
        else => @compileError("Expected a pointer to SPIR-V sampled image type, found '" ++ @typeName(@TypeOf(sampled_image)) ++ "'"),
    };
    const Result = @Vector(4, ImageSampledType(SampledImage));

    const image_info = switch (@typeInfo(SampledImage)) {
        .spirv => |spirv| switch (spirv) {
            .sampled_image => |sampled_image_info| @typeInfo(sampled_image_info).spirv.image,
            else => @compileError("Expected SPIR-V sampled image type, found '" ++ @typeName(SampledImage) ++ "'"),
        },
        else => @compileError("Expected SPIR-V sampled image type, found '" ++ @typeName(SampledImage) ++ "'"),
    };

    if (image_info.multisampled)
        @compileError("Can not implicitly sample a sampled image that was multisampled");

    // TOOD: If buffer dim is added, throw a compile error if the dimension is a buffer.

    return asm volatile (
        \\%loaded_sampler = OpLoad %SampledImage %sampled_image
        \\%ret            = OpImageSampleImplicitLod %Result %loaded_sampler %coordinate
        : [ret] "" (-> Result),
        : [SampledImage] "t" (SampledImage),
          [sampled_image] "" (sampled_image),
          [Result] "t" (Result),
          [coordinate] "" (coordinate),
    );
}

pub const ImageWriteOperands = struct {
    // TODO: Add more operands.
};

/// Write a texel to an image without a sampler.
/// The type of `image` must be a pointer to a SPIR-V image.
pub fn imageWriteUint(
    image: anytype,
    coordinate: ImageCoordinate(std.meta.Child(@TypeOf(image)), u32),
    texel: @Vector(4, ImageSampledType(std.meta.Child(@TypeOf(image)))),
    operands: ImageWriteOperands,
) void {
    _ = operands;

    const Image = switch (@typeInfo(@TypeOf(image))) {
        .pointer => |pointer| pointer.child,
        else => @compileError("Expected a pointer to SPIR-V image type, found '" ++ @typeName(@TypeOf(image)) ++ "'"),
    };

    const image_info = switch (@typeInfo(Image)) {
        .spirv => |spirv| switch (spirv) {
            .image => |info| info,
            else => @compileError("Expected SPIR-V image type, found '" ++ @typeName(Image) ++ "'"),
        },
        else => @compileError("Expected SPIR-V image type, found '" ++ @typeName(Image) ++ "'"),
    };

    switch (image_info.usage) {
        .unknown, .storage => {},
        else => @compileError("SPIR-V image must have unknown or storage usage"),
    }

    // TODO: If SubpassData dim is added, throw a compiler error if the image is arrayed and has the SubpassData dim.

    return asm volatile (
        \\%loaded_image   = OpLoad %Image %image
        \\                  OpImageWrite %loaded_image %coordinate %texel
        :
        : [Image] "t" (Image),
          [image] "" (image),
          [coordinate] "" (coordinate),
          [texel] "" (texel),
    );
}
