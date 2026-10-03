/// White point of the working/connection color space.
pub const WhitePoint = enum(i32) {
    any = -1, // module does not care about the white point
    d65 = 0,
    d50 = 1,
};

/// Transfer function (mapping) applied to the color values relative to the linear light domain.
/// typically linear
/// we will apply the OETF (Opto-Electronic Transfer Function) at the end of the pipeline
/// https://en.wikipedia.org/wiki/Transfer_functions_in_imaging
pub const Mapping = enum(i32) {
    any = -1, // module does not care about the mapping
    linear = 0,
    gamma_srgb = 1,
    // gamma_rec709 = 2,
};

/// Primaries (gamut) of the working/connection color space.
pub const Primaries = enum(i32) {
    any = -1, // module does not care about the primaries
    camera = 0,
    srgb = 1,
    // rec709 = 2,
    rec2020 = 3,
};

/// Describes the color profile a socket accepts/emits or that a connector
/// carries between modules/nodes.
white_point: WhitePoint,
primaries: Primaries,
mapping: Mapping,

const Self = @This();

pub const any = Self{
    .white_point = .any,
    .primaries = .any,
    .mapping = .any,
};

/// Whether `self` (an emitted profile) is accepted by `accepted` (a
/// socket's declared accept-profile). An `.any` field on either side
/// matches anything.
pub fn acceptedBy(self: Self, accepted: Self) bool {
    return profileFieldCompatible(self.white_point, accepted.white_point) and
        profileFieldCompatible(self.primaries, accepted.primaries) and
        profileFieldCompatible(self.mapping, accepted.mapping);
}

fn profileFieldCompatible(emitted: anytype, accepted: anytype) bool {
    return emitted == .any or accepted == .any or emitted == accepted;
}
