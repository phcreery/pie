const std = @import("std");

pub fn castStruct(comptime To: type, from: anytype) To {
    var result: To = undefined;
    inline for (@typeInfo(To).@"struct".field_names) |field_name| {
        @field(result, field_name) = @field(from, field_name);
    }
    return result;
}

pub fn castEnum(comptime To: type, from: anytype) To {
    comptime {
        const fields_a = std.meta.fieldNames(To);
        const fields_b = std.meta.fieldNames(@TypeOf(from));
        if (fields_a.len != fields_b.len) {
            @compileError("Enums do not have the same number of fields!");
        }
        for (fields_a, fields_b) |field_a, field_b| {
            if (!std.mem.eql(u8, field_a, field_b)) {
                @compileError("Field name mismatch: " ++ field_a ++ " vs " ++ field_b);
            }
        }
    }
    return @fromBackingInt(@intCast(@backingInt(from)));
}
