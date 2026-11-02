//! Parse and write colon-separated config files.
//!
//! Grammar (one record per line):
//!
//! ```
//! key:arg0:arg1:...
//! ```
//!
//! - `:` separates fields. A value that itself contains `:` must be the last
//!   field of its record; see `colonconfig.rest` below.
//! - Lines are `\n`-terminated; `\r` before the `\n` (CRLF) is stripped.
//! - Blank lines and lines starting with `#` are ignored.
//! - No escaping: no field except the last may contain `:`.
//!
//! Parsing is schema-driven and comptime: declare one struct per command
//! key whose fields map positionally onto the arguments (0, 1, 2, ...),
//! then build a `ColonConfig` with that schema and parse text into typed
//! entries. All string fields remain views into the source text (including
//! comptime strings); the doc allocates only its per-key lists. A field
//! that must consume the whole remainder (a value containing `:`) is marked
//! with `colonconfig.rest` in an optional `idx_map` decl.
//!
//! `doc.write` re-emits the raw text (comments, blank lines and unknown
//! keys preserved), so round-trips through `read`/`writeToFile` are exact.
//!
//! Example:
//!
//! ```zig
//! const ModuleCfgEntry = struct {
//!     module: []const u8,
//!     module_id: []const u8,
//! };
//!
//! const cc = colonconfig.ColonConfig(.{ .module = ModuleCfgEntry }).init(allocator);
//! const doc = try cc.parse(file);
//! defer doc.deinit();
//!
//! var it = doc.iter(ModuleCfgEntry);
//! while (it.next()) |m| {
//!     // m.module, m.module_id
//! }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Alias so decls/tests inside this file can write `colonconfig.rest` /
/// `colonconfig.ColonConfig(...)` the same way importing code does.
const colonconfig = @This();

/// `idx_map` element marking a field that takes the entire
/// remainder of the line after the previous field, verbatim (`:` allowed
/// inside). Any comptime string equal to `"rest"` works.
pub const rest: []const u8 = "rest";

/// Splits `key:args...`. A line without `:` has the whole line as `key`
/// and empty `args`.
pub fn splitKey(line: []const u8) struct { key: []const u8, args: []const u8 } {
    if (std.mem.indexOfScalar(u8, line, ':')) |c|
        return .{ .key = line[0..c], .args = line[c + 1 ..] };
    return .{ .key = line, .args = "" };
}

/// Fill a CfgEntry value from an argument string (everything after `key:`).
/// Missing arguments become `""` — line-level validation (e.g. warn and
/// skip) is up to the caller. Values needing `:` are read whole when their
/// field is marked `rest` in `idx_map`.
pub fn parseArgs(comptime CfgEntry: type, args: []const u8) CfgEntry {
    comptime validateCfgEntry(CfgEntry);
    var t = Tokenizer{ .line = args };
    var value: CfgEntry = undefined;
    // pos = index of the next unconsumed token.
    var pos: usize = 0;
    const info = @typeInfo(CfgEntry).@"struct";
    inline for (info.field_names, 0..) |name, i| {
        switch (argFor(CfgEntry, i)) {
            -1 => @field(value, name) = t.rest() orelse "",
            else => |idx| {
                // Skip ahead to the absolute argument index, then take it.
                const target: usize = @intCast(idx);
                while (pos < target) : (pos += 1) {
                    if (t.next() == null) {
                        pos = target;
                        break;
                    }
                }
                @field(value, name) = t.next() orelse "";
                pos = target + 1;
            },
        }
    }
    return value;
}

/// True when a `idx_map` element is the rest marker (any comptime
/// string equal to `rest`).
fn isRestMarker(comptime a: anytype) bool {
    const T = @TypeOf(a);
    if (T == comptime_int or T == usize or T == i64) return false;
    return comptime std.mem.eql(u8, a, rest);
}

/// Validates a CfgEntry at comptime: every field must be `[]const u8` and the
/// optional `idx_map` mapping must be well-formed.
fn validateCfgEntry(comptime CfgEntry: type) void {
    const info = @typeInfo(CfgEntry).@"struct";
    inline for (info.field_names, info.field_types) |name, typ| {
        if (typ != []const u8)
            @compileError("colonconfig: CfgEntry '" ++ @typeName(CfgEntry) ++ "' field '" ++ name ++ "' must be []const u8");
    }
    if (!@hasDecl(CfgEntry, "idx_map")) return;
    const args = CfgEntry.idx_map;
    if (args.len != info.field_types.len)
        @compileError("colonconfig: '" ++ @typeName(CfgEntry) ++ "'.idx_map has " ++ std.fmt.comptimePrint("{d}", .{args.len}) ++ " elements but the struct has " ++ std.fmt.comptimePrint("{d}", .{info.field_types.len}) ++ " fields");
    comptime var prev: i64 = -1;
    comptime var rest_seen = false;
    inline for (args) |a| {
        if (comptime isRestMarker(a)) {
            if (rest_seen)
                @compileError("colonconfig: '" ++ @typeName(CfgEntry) ++ "'.idx_map has more than one \"rest\"");
            rest_seen = true;
        } else if (comptime (@TypeOf(a) == comptime_int or @TypeOf(a) == usize)) {
            if (rest_seen)
                @compileError("colonconfig: '" ++ @typeName(CfgEntry) ++ "'.idx_map has an arg after \"rest\"");
            if (a <= prev)
                @compileError("colonconfig: '" ++ @typeName(CfgEntry) ++ "'.idx_map indices must increase");
            prev = a;
        } else {
            @compileError("colonconfig: '" ++ @typeName(CfgEntry) ++ "'.idx_map elements must be arg indices or \"rest\"");
        }
    }
}

/// Element `i` of CfgEntry's mapping: the argument index to take (>= 0) or -1
/// for "rest of the line". Default is plain positionality.
fn argFor(comptime CfgEntry: type, comptime field_idx: usize) i64 {
    if (!@hasDecl(CfgEntry, "idx_map")) return @intCast(field_idx);
    const a = CfgEntry.idx_map[field_idx];
    if (comptime isRestMarker(a)) return -1;
    return if (@TypeOf(a) == comptime_int) a else @intCast(a);
}

/// A parsed document: typed entries grouped per command key, plus the raw
/// text. All string fields point into `text`; `deinit` frees the groups
/// (and the text if this doc read it from a file).
pub const Doc = struct {
    /// Raw source text. Arena-owned iff created by `ColonConfig.read`.
    text: []const u8,
    arena_state: ?std.heap.ArenaAllocator = null,
    groups: []Group = &.{},

    /// Free the doc's groups and (if `read`-created) its text. Works on a
    /// `const` doc: `defer doc.deinit()`. The doc should not be reused.
    pub fn deinit(self: Doc) void {
        if (self.arena_state) |a| {
            var arena = a;
            arena.deinit();
        }
    }

    /// Iterate the parsed entries for `CfgEntry`'s key, in file order. Empty
    /// iterator when the file has no such entry.
    pub fn iter(self: *const Doc, comptime CfgEntry: type) Iter(CfgEntry) {
        for (self.groups) |g| {
            if (std.mem.eql(u8, g.type_name, @typeName(CfgEntry))) {
                const bytes: [*]const u8 = @ptrCast(g.values.items.ptr);
                const typed: []const CfgEntry = @ptrCast(@alignCast(bytes[0 .. g.len * @sizeOf(CfgEntry)]));
                return .{ .items = typed };
            }
        }
        return .{ .items = &.{} };
    }

    /// Serialize back to a writer: the raw text, plus a trailing newline if
    /// the last line lacks one. Round-trips `parse`/`read` exactly.
    pub fn write(self: *const Doc, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(self.text);
        if (self.text.len != 0 and self.text[self.text.len - 1] != '\n') try w.writeByte('\n');
    }

    /// Serialize straight to a file on disk.
    pub fn writeToFile(self: *const Doc, gpa: Allocator, io: std.Io, path: []const u8) !void {
        if (self.text.len == 0 or self.text[self.text.len - 1] == '\n') {
            return std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{ .sub_path = path, .data = self.text });
        }
        // Keep the trailing-newline invariant when writing back hand-edited
        // text that ended without one.
        const buf = try gpa.alloc(u8, self.text.len + 1);
        defer gpa.free(buf);
        @memcpy(buf[0..self.text.len], self.text);
        buf[self.text.len] = '\n';
        return std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{ .sub_path = path, .data = buf });
    }
};

/// Type-erased per-key group of parsed entries.
const Group = struct {
    /// The group's CfgEntry type name; `Doc.iter` matches against it.
    type_name: []const u8,
    /// Arena-backed list of CfgEntry values, contiguous, `len` elements.
    values: std.ArrayListUnmanaged(u8) = .empty,
    /// Element count.
    len: usize = 0,
};

/// Typed entry iterator over a doc.
fn Iter(comptime CfgEntry: type) type {
    comptime validateCfgEntry(CfgEntry);
    return struct {
        items: []const CfgEntry,
        index: usize = 0,

        /// The next entry, or null when exhausted.
        pub fn next(it: *@This()) ?CfgEntry {
            if (it.index >= it.items.len) return null;
            it.index += 1;
            return it.items[it.index - 1];
        }
    };
}

/// Build a ColonConfig over a comptime schema: the keys are the command
/// names and the values are the CfgEntry types parsed from those keys' lines.
/// Instantiate with `ColonConfig(.{ .module = ModuleCfgEntry }).init(gpa)`. A
/// ColonConfig is immutable after construction and carries only the
/// allocator; `parse`/`read` return docs and never mutate it.
pub fn ColonConfig(comptime schema: anytype) type {
    comptime validateSchema(schema);
    const keys = std.meta.fieldNames(@TypeOf(schema));
    return struct {
        gpa: Allocator,

        const Self = @This();

        /// Construct a ColonConfig. Infallible: it only stores `gpa`.
        pub fn init(gpa: Allocator) Self {
            return .{ .gpa = gpa };
        }

        fn DefOf(comptime i: usize) type {
            return @field(schema, keys[i]);
        }

        /// Parse in-memory text. The text must outlive the doc and every
        /// entry taken from it. `deinit` the doc when done.
        pub fn parse(self: Self, text: []const u8) Allocator.Error!Doc {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            errdefer arena.deinit();
            var doc = try self.parseAlloc(arena.allocator(), text);
            doc.arena_state = arena;
            return doc;
        }

        /// Parse using `a` for the entry groups; the returned doc does not
        /// own anything (`arena_state` is null) and `deinit` is a no-op —
        /// the caller frees `a`. Also the building block for `read`.
        fn parseAlloc(self: Self, a: Allocator, text: []const u8) Allocator.Error!Doc {
            _ = self;
            var groups = try a.alloc(Group, keys.len);
            inline for (keys, 0..) |_, i| {
                groups[i] = .{ .type_name = @typeName(DefOf(i)) };
            }

            var lit = LineIterator{ .reader = std.Io.Reader.fixed(text) };
            while (lit.next() catch unreachable) |line| {
                if (line.len == 0 or line[0] == '#') continue;
                const colon = std.mem.indexOfScalar(u8, line, ':');
                const key = line[0 .. colon orelse line.len];
                const args = if (colon) |c| line[c + 1 ..] else "";
                inline for (keys, 0..) |_, i| {
                    if (std.mem.eql(u8, key, keys[i])) {
                        try appendEntry(a, &groups[i], DefOf(i), args);
                    }
                }
            }

            return .{ .text = text, .groups = groups };
        }

        /// Read a file and parse it. The doc owns the file text; `deinit`
        /// frees everything.
        pub fn read(self: Self, io: std.Io, path: []const u8) !Doc {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            errdefer arena.deinit();
            const text = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, arena.allocator(), .unlimited);
            var doc = try self.parseAlloc(arena.allocator(), text);
            doc.arena_state = arena;
            doc.text = text;
            return doc;
        }
    };
}

/// Stores a CfgEntry value copy into a group.
fn storeValue(a: Allocator, g: *Group, comptime CfgEntry: type, value: CfgEntry) Allocator.Error!void {
    const old_len = g.values.items.len;
    try g.values.resize(a, old_len + @sizeOf(CfgEntry));
    const slot: *CfgEntry = @ptrCast(@alignCast(g.values.items[old_len..][0..@sizeOf(CfgEntry)]));
    slot.* = value;
    g.len += 1;
}

/// Appends one parsed entry (a CfgEntry value) to a group.
fn appendEntry(a: Allocator, g: *Group, comptime CfgEntry: type, args: []const u8) Allocator.Error!void {
    try storeValue(a, g, CfgEntry, parseArgs(CfgEntry, args));
}

/// Validates the ColonConfig schema: tuple of unique comptime keys, each with a
/// struct CfgEntry (validated via `validateCfgEntry` at instantiation).
fn validateSchema(comptime schema: anytype) void {
    const keys = std.meta.fieldNames(@TypeOf(schema));
    if (@typeInfo(@TypeOf(schema)).@"struct".is_tuple)
        @compileError("colonconfig: schema must use named keys (.{ .module = ModuleCfgEntry, ... })");
    inline for (keys, 0..) |key, i| {
        validateCfgEntry(@field(schema, key));
        inline for (keys[0..i]) |other| {
            if (std.mem.eql(u8, key, other))
                @compileError("colonconfig: duplicate key '" ++ key ++ "' in ColonConfig schema");
        }
    }
}

/// Raw line iteration over any `std.Io.Reader`.
pub const LineIterator = struct {
    reader: std.Io.Reader,

    pub const Error = error{ ReadFailed, StreamTooLong };

    pub fn init(reader: std.Io.Reader) LineIterator {
        return LineIterator{ .reader = reader };
    }

    /// The next line without its `\n` (and `\r`), or null at end of input.
    /// A final line without a terminator is still returned. Slices are views
    /// into the reader's buffer, valid until the following call.
    pub fn next(l: *LineIterator) Error!?[]const u8 {
        if (l.reader.seek == l.reader.end) return null;
        // Inclusive take is the only delimiter API that advances past the
        // delimiter in 0.17.0 (exclusive leaves the seek at it), so take the
        // `\n` and strip it here.
        const line = l.reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            // Unterminated final line: the rest of the buffer is the line
            // verbatim; there is no `\n` to strip.
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

/// Splits one line on `:`. Views stay valid while the source line does.
pub const Tokenizer = struct {
    line: []const u8,
    pos: usize = 0,

    /// The next `:`-delimited field, or null when exhausted. A trailing `:`
    /// yields a final empty field, matching `std.mem.splitScalar`.
    pub fn next(t: *Tokenizer) ?[]const u8 {
        if (t.pos > t.line.len) return null;
        const start = t.pos;
        if (std.mem.indexOfScalarPos(u8, t.line, start, ':')) |i| {
            t.pos = i + 1;
            return t.line[start..i];
        }
        t.pos = t.line.len + 1;
        return t.line[start..];
    }

    /// The entire remainder after the consumed fields, verbatim (`:` may
    /// occur inside). Null when nothing remains; `""` is an explicit empty
    /// value (`"key:"`).
    pub fn rest(t: *Tokenizer) ?[]const u8 {
        if (t.pos > t.line.len) return null;
        const r = t.line[t.pos..];
        t.pos = t.line.len + 1;
        return r;
    }
};

/// Write one record frame, without a line terminator: `key:arg0:arg1...`.
/// String arguments are written verbatim; integers and floats are formatted
/// decimal; slices of integers/floats are written `:`-joined (dynamic value
/// lists, e.g. vector params). A value containing `:` must be the last
/// argument.
pub fn writeRecord(w: *std.Io.Writer, key: []const u8, args: anytype) std.Io.Writer.Error!void {
    try w.writeAll(key);
    inline for (args) |a| {
        try w.writeByte(':');
        try writeArg(w, a);
    }
}

/// Write one record line: `CfgEntry.key:arg0:...\n`, with `key` taken from
/// the CfgEntry's `pub const key` declaration and one argument per CfgEntry
/// field. Arguments are formatted as in `writeRecord`.
pub fn writeEntry(w: *std.Io.Writer, comptime CfgEntry: type, args: anytype) std.Io.Writer.Error!void {
    comptime {
        if (@typeInfo(CfgEntry) != .@"struct" or !@hasDecl(CfgEntry, "key"))
            @compileError("colonconfig: '" ++ @typeName(CfgEntry) ++ "' needs a `pub const key` for writeEntry");
        const n_fields = @typeInfo(CfgEntry).@"struct".field_types.len;
        const n_args = @typeInfo(@TypeOf(args)).@"struct".field_types.len;
        if (n_args != n_fields)
            @compileError("colonconfig: writeEntry for '" ++ @typeName(CfgEntry) ++ "' needs " ++ std.fmt.comptimePrint("{d}", .{n_fields}) ++ " arguments, got " ++ std.fmt.comptimePrint("{d}", .{n_args}));
    }
    try writeRecord(w, CfgEntry.key, args);
    try w.writeByte('\n');
}

fn writeArg(w: *std.Io.Writer, a: anytype) std.Io.Writer.Error!void {
    switch (@typeInfo(@TypeOf(a))) {
        .int, .comptime_int => return w.print("{d}", .{a}),
        .float, .comptime_float => return w.print("{d}", .{a}),
        .pointer => |p| switch (p.size) {
            .slice => switch (@typeInfo(p.child)) {
                // byte slices are strings; only non-u8 ints format as lists
                .int => if (p.child == u8) return w.writeAll(a) else return writeNumberList(w, a),
                .float => return writeNumberList(w, a),
                else => return w.writeAll(a),
            },
            else => return w.writeAll(a),
        },
        else => @compileError("colonconfig: unsupported writeEntry argument type " ++ @typeName(@TypeOf(a))),
    }
}

fn writeNumberList(w: *std.Io.Writer, values: anytype) std.Io.Writer.Error!void {
    for (values, 0..) |v, i| {
        if (i != 0) try w.writeByte(':');
        try w.print("{d}", .{v});
    }
}

test "colonconfig api test" {
    const allocator = std.testing.allocator;

    // this is an example for the API might look like
    const ModuleCfgEntry = struct {
        module: []const u8,
        module_id: []const u8,
    };

    const ConnectionCfgEntry = struct {
        from: []const u8,
        from_id: []const u8,
        output: []const u8,
        to: []const u8,
        to_id: []const u8,
        input: []const u8,
    };

    const ParamCfgEntry = struct {
        module: []const u8,
        module_id: []const u8,
        name: []const u8,
        value: []const u8,
        pub const idx_map = .{ 0, 1, 2, colonconfig.rest };
    };

    const file =
        \\module:i-raw:01
        \\connect:i-raw:01:output:format:01:input
        \\param:i-raw:01:filename:testing/images/DSC_6765.NEF
    ;

    const cc: ColonConfig(.{
        .module = ModuleCfgEntry,
        .connect = ConnectionCfgEntry,
        .param = ParamCfgEntry,
    }) = .init(allocator);

    const doc = try cc.parse(file);
    defer doc.deinit();

    var mods = doc.iter(ModuleCfgEntry);
    var n_modules: usize = 0;
    while (mods.next()) |m| {
        try std.testing.expectEqualStrings("i-raw", m.module);
        try std.testing.expectEqualStrings("01", m.module_id);
        n_modules += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), n_modules);

    var conns = doc.iter(ConnectionCfgEntry);
    var n_conns: usize = 0;
    while (conns.next()) |c| {
        try std.testing.expectEqualStrings("i-raw", c.from);
        try std.testing.expectEqualStrings("01", c.from_id);
        try std.testing.expectEqualStrings("output", c.output);
        try std.testing.expectEqualStrings("format", c.to);
        try std.testing.expectEqualStrings("01", c.to_id);
        try std.testing.expectEqualStrings("input", c.input);
        n_conns += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), n_conns);

    var params = doc.iter(ParamCfgEntry);
    var n_params: usize = 0;
    while (params.next()) |p| {
        try std.testing.expectEqualStrings("i-raw", p.module);
        try std.testing.expectEqualStrings("01", p.module_id);
        try std.testing.expectEqualStrings("filename", p.name);
        try std.testing.expectEqualStrings("testing/images/DSC_6765.NEF", p.value);
        n_params += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), n_params);
}

test "missing keys and unknown lines are skipped, comments preserved in write" {
    const ModuleCfgEntry = struct {
        module: []const u8,
        module_id: []const u8,
    };
    const cc: ColonConfig(.{ .module = ModuleCfgEntry }) = .init(std.testing.allocator);

    const file =
        \\# a comment
        \\
        \\module:i-raw:01
        \\garbage without a colon
        \\module:format:02
    ;
    const doc = try cc.parse(file);
    defer doc.deinit();

    var it = doc.iter(ModuleCfgEntry);
    try std.testing.expectEqualStrings("i-raw", it.next().?.module);
    try std.testing.expectEqualStrings("format", it.next().?.module);
    try std.testing.expect(it.next() == null);

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    try doc.write(&w.writer);
    try std.testing.expectEqualStrings(file ++ "\n", w.written());
}

test "value may contain colons when the field is colonconfig.rest" {
    const ParamCfgEntry = struct {
        module: []const u8,
        module_id: []const u8,
        name: []const u8,
        value: []const u8,
        pub const idx_map = .{ 0, 1, 2, colonconfig.rest };
    };
    const cc = ColonConfig(.{ .param = ParamCfgEntry }).init(std.testing.allocator);

    const doc = try cc.parse("param:mod:01:path:a:b:c");
    defer doc.deinit();

    var it = doc.iter(ParamCfgEntry);
    const p = it.next().?;
    try std.testing.expectEqualStrings("mod", p.module);
    try std.testing.expectEqualStrings("01", p.module_id);
    try std.testing.expectEqualStrings("path", p.name);
    try std.testing.expectEqualStrings("a:b:c", p.value);
    try std.testing.expect(it.next() == null);
}

test "empty value is an explicit empty string" {
    const ParamCfgEntry = struct {
        module: []const u8,
        module_id: []const u8,
        name: []const u8,
        value: []const u8,
    };
    const cc = ColonConfig(.{ .param = ParamCfgEntry }).init(std.testing.allocator);

    const doc = try cc.parse("param:mod:01:scale:");
    defer doc.deinit();
    var it = doc.iter(ParamCfgEntry);
    const p = it.next().?;
    try std.testing.expectEqualStrings("", p.value);
}

test "doc with no matching entries iterates empty" {
    const ModuleCfgEntry = struct {
        module: []const u8,
        module_id: []const u8,
    };
    const cc = ColonConfig(.{ .module = ModuleCfgEntry }).init(std.testing.allocator);

    const doc = try cc.parse("");
    defer doc.deinit();
    var it = doc.iter(ModuleCfgEntry);
    try std.testing.expect(it.next() == null);
}

test "crlf is tolerated" {
    const ParamCfgEntry = struct {
        module: []const u8,
        module_id: []const u8,
        name: []const u8,
        value: []const u8,
    };
    const cc = ColonConfig(.{ .param = ParamCfgEntry }).init(std.testing.allocator);

    const doc = try cc.parse("param:x:y:z:1\r\nparam:a:b:c:d\r\n");
    defer doc.deinit();
    var it = doc.iter(ParamCfgEntry);
    const p = it.next().?;
    try std.testing.expectEqualStrings("x", p.module);
    try std.testing.expectEqualStrings("y", p.module_id);
    try std.testing.expectEqualStrings("z", p.name);
    try std.testing.expectEqualStrings("1", p.value);
}

test "read and writeToFile round-trip through the filesystem" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const ModuleCfgEntry = struct {
        module: []const u8,
        module_id: []const u8,
    };
    const ParamCfgEntry = struct {
        module: []const u8,
        module_id: []const u8,
        name: []const u8,
        value: []const u8,
        pub const idx_map = .{ 0, 1, 2, colonconfig.rest };
    };
    const cc = ColonConfig(.{ .module = ModuleCfgEntry, .param = ParamCfgEntry }).init(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original =
        \\# hand-edited
        \\module:i-raw:01
        \\
        \\param:i-raw:01:filename:testing/images/DSC_6765.NEF
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "colonconfig_test.pst", .data = original });

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/colonconfig_test.pst", .{tmp.sub_path});

    var doc = try cc.read(io, path);
    defer doc.deinit();

    try std.testing.expectEqualStrings(original, doc.text);

    var mods = doc.iter(ModuleCfgEntry);
    try std.testing.expectEqualStrings("i-raw", mods.next().?.module);
    try std.testing.expect(mods.next() == null);

    var params = doc.iter(ParamCfgEntry);
    try std.testing.expectEqualStrings("testing/images/DSC_6765.NEF", params.next().?.value);

    try doc.writeToFile(allocator, io, path);
    var reread = try cc.read(io, path);
    defer reread.deinit();
    // writeToFile guarantees a trailing newline; original lacks one
    try std.testing.expectEqualStrings(original ++ "\n", reread.text);
}

test "read of missing file errors" {
    const ModuleCfgEntry = struct {
        module: []const u8,
        module_id: []const u8,
    };
    const cc = ColonConfig(.{ .module = ModuleCfgEntry }).init(std.testing.allocator);
    try std.testing.expectError(error.FileNotFound, cc.read(std.testing.io, "colonconfig_missing_file.zzz"));
}

test "writeEntry writes one record with the key from the CfgEntry" {
    const ModuleCfgEntry = struct {
        module: []const u8,
        module_id: []const u8,
        pub const key = "module";
    };
    const ParamCfgEntry = struct {
        module: []const u8,
        module_id: []const u8,
        name: []const u8,
        value: []const u8,
        pub const key = "param";
        pub const idx_map = .{ 0, 1, 2, colonconfig.rest };
    };

    var w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer w.deinit();
    try writeEntry(&w.writer, ModuleCfgEntry, .{ "i-raw", "01" });
    try writeEntry(&w.writer, ParamCfgEntry, .{ "i-raw", "01", "exposure", "1.5" });
    // slices of numbers write as a ':'-joined dynamic value list
    const gains: []const f32 = &.{ 1.5, -2.0 };
    try writeEntry(&w.writer, ParamCfgEntry, .{ "i-raw", "01", "gain", gains });
    try std.testing.expectEqualStrings(
        "module:i-raw:01\nparam:i-raw:01:exposure:1.5\nparam:i-raw:01:gain:1.5:-2\n",
        w.written(),
    );
}

test "splitKey and parseArgs power line-ordered apply" {
    const ConnectCfgEntry = struct {
        src: []const u8,
        src_id: []const u8,
        src_sock: []const u8,
        dst: []const u8,
        dst_id: []const u8,
        dst_sock: []const u8,
    };
    const ParamCfgEntry = struct {
        module: []const u8,
        module_id: []const u8,
        name: []const u8,
        value: []const u8,
        pub const idx_map = .{ 0, 1, 2, colonconfig.rest };
    };

    const split = splitKey("connect:i-raw:01:output:format:01:input");
    try std.testing.expectEqualStrings("connect", split.key);
    const c = parseArgs(ConnectCfgEntry, split.args);
    try std.testing.expectEqualStrings("i-raw", c.src);
    try std.testing.expectEqualStrings("01", c.src_id);
    try std.testing.expectEqualStrings("output", c.src_sock);
    try std.testing.expectEqualStrings("format", c.dst);
    try std.testing.expectEqualStrings("01", c.dst_id);
    try std.testing.expectEqualStrings("input", c.dst_sock);

    // missing args become ""
    const short = splitKey("module:i-raw");
    try std.testing.expectEqualStrings("module", short.key);
    const m = parseArgs(ConnectCfgEntry, short.args);
    try std.testing.expectEqualStrings("i-raw", m.src);
    try std.testing.expectEqualStrings("", m.dst_sock);

    // no colon: whole line is the command
    const bare = splitKey("garbage");
    try std.testing.expectEqualStrings("garbage", bare.key);
    try std.testing.expectEqualStrings("", bare.args);

    // rest takes the verbatim remainder
    const p = parseArgs(ParamCfgEntry, splitKey("param:mod:01:filename:a:b:c").args);
    try std.testing.expectEqualStrings("mod", p.module);
    try std.testing.expectEqualStrings("01", p.module_id);
    try std.testing.expectEqualStrings("filename", p.name);
    try std.testing.expectEqualStrings("a:b:c", p.value);
}

test "line iterator handles all shapes" {
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
        var lit = LineIterator{ .reader = std.Io.Reader.fixed(c.text) };
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
