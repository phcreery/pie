/// White point of the working/connection color space.
pub const WhitePoint = enum(i32) {
    any = -1, // module does not care about the white point
    d65 = 0,
    d50 = 1,
};

/// Primaries (gamut) of the working/connection color space.
pub const Primaries = enum(i32) {
    any = -1, // module does not care about the primaries
    camera = 0,
    rec709 = 1,
    rec2020 = 2,
};

/// Describes the color profile a socket accepts/emits or that a connector
/// carries between modules/nodes.
white_point: WhitePoint,
primaries: Primaries,

const Self = @This();

pub const any = Self{ .white_point = .any, .primaries = .any };

/// Whether `self` (an emitted profile) is accepted by `accepted` (a
/// socket's declared accept-profile). An `.any` field on either side
/// matches anything.
pub fn acceptedBy(self: Self, accepted: Self) bool {
    return profileFieldCompatible(self.white_point, accepted.white_point) and
        profileFieldCompatible(self.primaries, accepted.primaries);
}

fn profileFieldCompatible(emitted: anytype, accepted: anytype) bool {
    return emitted == .any or accepted == .any or emitted == accepted;
}
