//! Read and write colon-separated configuration records.
//!
//! Grammar:
//!
//! ```
//! key:field0:field1:...
//! ```
//!
//! Rules:
//!
//! - A colon (:) separates fields.
//! - Only the last field can contain a colon. See `rest`.
//! - A line ends at a newline. A CR before the newline is removed.
//! - Empty lines and lines that start with # are ignored.
//! - There is no escape character.
//!
//! A schema is a tagged union. Each tag name is a key. Each payload is a
//! struct. The struct holds the record fields in order. The key is in the tag
//! name only.
//!
//! Example:
//!
//! ```zig
//! const Schema = union(enum) {
//!     module: struct { name: []const u8, id: []const u8 },
//!     param: struct {
//!         name: []const u8,
//!         id: []const u8,
//!         param: []const u8,
//!         value: colonconfig.Value,
//!         pub const idx_map = .{ 0, 1, 2, colonconfig.rest };
//!     },
//! };
//!
//! const Config = colonconfig.ColonConfig(Schema);
//!
//! var it = Config.EntryIterator.init(reader);
//! while (try it.next()) |entry| switch (entry) {
//!     .module => |m| use(m),
//!     .param => |p| use(p),
//! };
//!
//! try Config.writeEntry(writer, .{ .module = .{ .name = "i-raw", .id = "01" } });
//! ```

const std = @import("std");

const slog = std.log.scoped(.colonconfig);

/// Alias for use inside this file.
const colonconfig = @This();

/// Mark a field that takes the rest of the line. The field can contain a
/// colon. Any comptime string equal to "rest" works.
pub const rest: []const u8 = "rest";

/// A field value that a writer can write in more than one form. The parser
/// always returns `.text`.
/// TODO: this is dupliceted with `Value` in `engine/Param.zig`
pub const Value = union(enum) {
    text: []const u8,
    i32: []align(1) const i32,
    f32: []align(1) const f32,
    enum_u32: []align(1) const u32,
};

/// Convert one parsed argument to a field type.
fn argValue(comptime typ: type, s: []const u8) typ {
    if (comptime typ == Value) return .{ .text = s };
    return s;
}

/// Split a line into a key and an argument string. A line without a colon has
/// an empty argument string.
fn splitKey(line: []const u8) struct { key: []const u8, args: []const u8 } {
    if (std.mem.indexOfScalar(u8, line, ':')) |c|
        return .{ .key = line[0..c], .args = line[c + 1 ..] };
    return .{ .key = line, .args = "" };
}

/// Fill a record struct from the argument string. A missing argument becomes
/// "". The caller checks the line. A field marked `rest` takes the remainder.
fn parseArgs(comptime CfgEntry: type, args: []const u8) CfgEntry {
    comptime validateCfgEntry(CfgEntry);
    var t = Tokenizer{ .line = args };
    var value: CfgEntry = undefined;
    var pos: usize = 0;
    const info = @typeInfo(CfgEntry).@"struct";
    inline for (info.field_names, info.field_types, 0..) |name, typ, i| {
        switch (argFor(CfgEntry, i)) {
            -1 => @field(value, name) = argValue(typ, t.rest() orelse ""),
            else => |idx| {
                const target: usize = @intCast(idx);
                // Advance to the field index. Stop if the line is short.
                while (pos < target) : (pos += 1) {
                    if (t.next() == null) {
                        pos = target;
                        break;
                    }
                }
                @field(value, name) = argValue(typ, t.next() orelse "");
                pos = target + 1;
            },
        }
    }
    return value;
}

/// Return true if an idx_map element is the rest marker.
fn isRestMarker(comptime a: anytype) bool {
    const T = @TypeOf(a);
    if (T == comptime_int or T == usize or T == i64) return false;
    return comptime std.mem.eql(u8, a, rest);
}

/// Check a record struct at comptime. Each field must be []const u8 or Value.
/// Check idx_map if the struct declares it.
fn validateCfgEntry(comptime CfgEntry: type) void {
    const info = @typeInfo(CfgEntry).@"struct";
    inline for (info.field_names, info.field_types) |name, typ| {
        if (typ != []const u8 and typ != Value)
            @compileError("colonconfig: field '" ++ name ++ "' of '" ++ @typeName(CfgEntry) ++ "' must be []const u8 or colonconfig.Value");
    }
    if (!@hasDecl(CfgEntry, "idx_map")) return;
    const args = CfgEntry.idx_map;
    if (args.len != info.field_types.len)
        @compileError("colonconfig: idx_map length does not match field count in '" ++ @typeName(CfgEntry) ++ "'");
    comptime var prev: i64 = -1;
    comptime var rest_seen = false;
    inline for (args) |a| {
        if (comptime isRestMarker(a)) {
            if (rest_seen)
                @compileError("colonconfig: more than one rest marker in '" ++ @typeName(CfgEntry) ++ "'");
            rest_seen = true;
        } else if (comptime (@TypeOf(a) == comptime_int or @TypeOf(a) == usize)) {
            if (rest_seen)
                @compileError("colonconfig: index after rest marker in '" ++ @typeName(CfgEntry) ++ "'");
            if (a <= prev)
                @compileError("colonconfig: idx_map indices must increase in '" ++ @typeName(CfgEntry) ++ "'");
            prev = a;
        } else {
            @compileError("colonconfig: idx_map elements must be indices or the rest marker in '" ++ @typeName(CfgEntry) ++ "'");
        }
    }
}

/// Return the argument index of a field. -1 means rest of the line. The
/// default is the field position.
fn argFor(comptime CfgEntry: type, comptime field_idx: usize) i64 {
    if (!@hasDecl(CfgEntry, "idx_map")) return @intCast(field_idx);
    const a = CfgEntry.idx_map[field_idx];
    if (comptime isRestMarker(a)) return -1;
    return if (@TypeOf(a) == comptime_int) a else @intCast(a);
}

/// Build config helpers from a tagged-union schema. Each tag name is a key.
/// Each payload is a record struct.
pub fn ColonConfig(comptime Schema: type) type {
    comptime validateSchema(Schema);
    const info = @typeInfo(Schema).@"union";
    return struct {
        /// Yield one typed entry for each known line. Skip empty lines,
        /// comments and unknown keys. Log an unknown key.
        pub const EntryIterator = struct {
            lines: LineIterator,
            /// Line number of the last line the iterator returned.
            line_no: usize = 0,

            pub const Error = LineIterator.Error;

            pub fn init(reader: std.Io.Reader) @This() {
                return .{ .lines = .init(reader) };
            }

            /// Return the next known entry, or null at the end.
            pub fn next(self: *@This()) Error!?Schema {
                while (try self.lines.next()) |line| {
                    self.line_no += 1;
                    if (line.len == 0 or line[0] == '#') continue;
                    const split = splitKey(line);
                    inline for (info.field_names, info.field_types) |name, typ| {
                        if (std.mem.eql(u8, split.key, name)) {
                            return @unionInit(Schema, name, parseArgs(typ, split.args));
                        }
                    }
                    slog.warn("line {d}: unknown key '{s}', skipping", .{ self.line_no, split.key });
                }
                return null;
            }
        };

        /// Write one record without a line end. Write the tag first. Write a
        /// colon and a field for each struct field.
        pub fn writeRecord(w: *std.Io.Writer, entry: Schema) std.Io.Writer.Error!void {
            switch (entry) {
                inline else => |payload| {
                    const tag = std.meta.activeTag(entry);
                    const payload_info = @typeInfo(@TypeOf(payload)).@"struct";
                    try w.writeAll(@tagName(tag));
                    inline for (payload_info.field_names, payload_info.field_types) |name, typ| {
                        try w.writeByte(':');
                        const field = @field(payload, name);
                        if (comptime typ == Value) {
                            try writeValue(w, field);
                        } else {
                            try w.writeAll(field);
                        }
                    }
                },
            }
        }

        /// Write one record and a newline.
        pub fn writeEntry(w: *std.Io.Writer, entry: Schema) std.Io.Writer.Error!void {
            try writeRecord(w, entry);
            try w.writeByte('\n');
        }
    };
}

/// Check that the schema is a tagged union. Check each payload.
fn validateSchema(comptime Schema: type) void {
    const info = @typeInfo(Schema);
    if (info != .@"union" or info.@"union".tag_type == null)
        @compileError("colonconfig: schema must be a tagged union, e.g. union(enum) { .module = ModuleCfgEntry }");
    inline for (info.@"union".field_types) |typ| validateCfgEntry(typ);
}

/// Return the lines of a reader.
pub const LineIterator = struct {
    reader: std.Io.Reader,

    pub const Error = error{ ReadFailed, StreamTooLong };

    pub fn init(reader: std.Io.Reader) LineIterator {
        return .{ .reader = reader };
    }

    /// Return the next line without a line end, or null at the end. Return a
    /// final line that has no line end. The slice is valid until the next call.
    pub fn next(l: *LineIterator) Error!?[]const u8 {
        if (l.reader.seek == l.reader.end) return null;
        // zig 0.17.0: takeDelimiterExclusive does not consume the delimiter.
        // Take the line with the delimiter. Remove the delimiter here.
        const line = l.reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                const last = l.reader.buffer[l.reader.seek..l.reader.end];
                l.reader.seek = l.reader.end;
                return stripCr(last);
            },
            else => |e| return e,
        };
        return stripCr(line[0 .. line.len - 1]);
    }

    fn stripCr(s: []const u8) []const u8 {
        if (s.len > 0 and s[s.len - 1] == '\r') return s[0 .. s.len - 1];
        return s;
    }
};

/// Split a line at colons.
const Tokenizer = struct {
    line: []const u8,
    pos: usize = 0,

    /// Return the next field, or null at the end. A final colon yields an empty
    /// field.
    fn next(t: *Tokenizer) ?[]const u8 {
        if (t.pos > t.line.len) return null;
        const start = t.pos;
        if (std.mem.indexOfScalarPos(u8, t.line, start, ':')) |i| {
            t.pos = i + 1;
            return t.line[start..i];
        }
        t.pos = t.line.len + 1;
        return t.line[start..];
    }

    /// Return the rest of the line. Return null if no text remains. An empty
    /// string means an empty value.
    fn rest(t: *Tokenizer) ?[]const u8 {
        if (t.pos > t.line.len) return null;
        const r = t.line[t.pos..];
        t.pos = t.line.len + 1;
        return r;
    }
};

fn writeValue(w: *std.Io.Writer, value: Value) std.Io.Writer.Error!void {
    switch (value) {
        .text => |s| try w.writeAll(s),
        .i32 => |values| try writeNumberList(i32, w, values),
        .f32 => |values| try writeNumberList(f32, w, values),
        .enum_u32 => |values| try writeNumberList(u32, w, values),
    }
}

fn writeNumberList(comptime T: type, w: *std.Io.Writer, values: []align(1) const T) std.Io.Writer.Error!void {
    for (values, 0..) |v, i| {
        if (i != 0) try w.writeByte(':');
        try w.print("{d}", .{v});
    }
}

test "entry iterator yields typed records and skips unknown lines" {
    const Schema = union(enum) {
        module: struct {
            name: []const u8,
            id: []const u8,
        },
        param: struct {
            name: []const u8,
            id: []const u8,
            param: []const u8,
            value: colonconfig.Value,
            pub const idx_map = .{ 0, 1, 2, colonconfig.rest };
        },
    };

    const text =
        \\# comment
        \\
        \\module:i-raw:01
        \\unknown:record
        \\param:i-raw:01:filename:a/b:c.NEF
    ;
    var it = ColonConfig(Schema).EntryIterator.init(std.Io.Reader.fixed(text));

    const first = (try it.next()).?;
    try std.testing.expect(first == .module);
    try std.testing.expectEqualStrings("i-raw", first.module.name);
    try std.testing.expectEqualStrings("01", first.module.id);
    try std.testing.expectEqual(@as(usize, 3), it.line_no);

    const second = (try it.next()).?;
    try std.testing.expect(second == .param);
    try std.testing.expectEqualStrings("filename", second.param.param);
    try std.testing.expectEqualStrings("a/b:c.NEF", second.param.value.text);
    try std.testing.expectEqual(@as(usize, 5), it.line_no);

    try std.testing.expect((try it.next()) == null);
}

test "writeRecord and writeEntry write schema records" {
    const Schema = union(enum) {
        module: struct {
            name: []const u8,
            id: []const u8,
        },
        param: struct {
            name: []const u8,
            id: []const u8,
            param: []const u8,
            value: colonconfig.Value,
        },
    };
    const Config = ColonConfig(Schema);

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();

    // writeRecord writes no line end.
    try Config.writeRecord(&w.writer, .{ .module = .{ .name = "i-raw", .id = "01" } });
    try Config.writeEntry(&w.writer, .{ .param = .{
        .name = "i-raw",
        .id = "01",
        .param = "filename",
        .value = .{ .text = "a/b:c.NEF" },
    } });
    const gains: []align(1) const f32 = &.{ 1.5, -2.0 };
    try Config.writeEntry(&w.writer, .{ .param = .{
        .name = "i-raw",
        .id = "01",
        .param = "gain",
        .value = .{ .f32 = gains },
    } });
    const mask: []align(1) const i32 = &.{ 1, -2 };
    try Config.writeEntry(&w.writer, .{ .param = .{
        .name = "i-raw",
        .id = "01",
        .param = "mask",
        .value = .{ .i32 = mask },
    } });

    try std.testing.expectEqualStrings(
        "module:i-raw:01" ++
            "param:i-raw:01:filename:a/b:c.NEF\n" ++
            "param:i-raw:01:gain:1.5:-2\n" ++
            "param:i-raw:01:mask:1:-2\n",
        w.written(),
    );
}

test "line iterator returns lines without line ends" {
    const Case = struct { text: []const u8, want: []const []const u8 };
    const cases = [_]Case{
        .{ .text = "abc", .want = &.{"abc"} },
        .{ .text = "abc\n", .want = &.{"abc"} },
        .{ .text = "a\n\nb", .want = &.{ "a", "", "b" } },
        .{ .text = "", .want = &.{} },
        .{ .text = "\n", .want = &.{""} },
        .{ .text = "a\r\nb", .want = &.{ "a", "b" } },
    };
    for (cases) |c| {
        var lit = LineIterator.init(std.Io.Reader.fixed(c.text));
        var got: [4][]const u8 = undefined;
        var n: usize = 0;
        while (try lit.next()) |line| {
            try std.testing.expect(n < got.len);
            got[n] = line;
            n += 1;
        }
        try std.testing.expectEqual(c.want.len, n);
        for (c.want, got[0..n]) |want, have| try std.testing.expectEqualStrings(want, have);
    }
}
