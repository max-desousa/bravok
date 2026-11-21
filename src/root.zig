const std = @import("std");
const builtin = @import("builtin");

fn diagnostic(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    std.log.err(fmt, args);
}

/// One row of a compile-time CSV schema.
///
/// Columns: `short,long,type,arity,default,help`
///
/// `short` is empty or one character. `long` is the `--name` and, with `-`
/// turned into `_`, the result field. `type` is the value type (`?` makes it
/// optional). `arity` is `0` (flag), `1`, `+` (one or more), or `*` (zero or
/// more). `+` and `*` take each argument that follows until the next option.
///
/// `default` is used when the option is omitted. On a `?` type, a blank cell
/// or `null` is null. A non-optional type with a default is not required; a
/// blank cell on a non-optional number or bool is required. A blank
/// `[]const u8` is the empty string. For `+` and `*`, `default` is a
/// comma-separated list (`a.txt,b.txt`); quote that cell when it contains a
/// comma. `+` with no items is required. `*` with no items is an empty list.
/// Help text may contain commas; quote a field to keep a comma inside
/// it, and double a quote to escape one.
pub const ArgDef = struct {
    short: ?u8 = null,
    long: []const u8,
    type_name: []const u8,
    arity: Arity,
    default_str: []const u8,
    help: []const u8,
    /// Long name, sanitized into a struct field identifier.
    field_name: []const u8,
};

pub const Arity = enum {
    flag,
    one,
    one_or_more,
    zero_or_more,
};

pub const Error = error{
    UnknownOption,
    MissingValue,
    MissingArgument,
    UnexpectedValue,
    UnexpectedPositional,
    InvalidValue,
    Help,
};

const max_defs = 64;

// ---------------------------------------------------------------------------
// Comptime CSV parsing
// ---------------------------------------------------------------------------

fn parseArity(comptime s: []const u8) Arity {
    if (s.len == 0 or std.mem.eql(u8, s, "1")) return .one;
    if (std.mem.eql(u8, s, "0")) return .flag;
    if (std.mem.eql(u8, s, "+")) return .one_or_more;
    if (std.mem.eql(u8, s, "*")) return .zero_or_more;
    @compileError("unsupported arity: " ++ s);
}

fn isIdentChar(c: u8, first: bool) bool {
    if (c == '_') return true;
    if (c >= 'A' and c <= 'Z') return true;
    if (c >= 'a' and c <= 'z') return true;
    if (!first and c >= '0' and c <= '9') return true;
    return false;
}

/// Stable comptime copy. `-` becomes `_`.
fn fieldNameFrom(comptime raw: []const u8) []const u8 {
    if (raw.len == 0) @compileError("argument needs a long or short name");
    var buf: [raw.len]u8 = undefined;
    for (raw, 0..) |c, i| {
        const mapped: u8 = if (c == '-') '_' else c;
        if (!isIdentChar(mapped, i == 0)) @compileError("invalid argument name: " ++ raw);
        buf[i] = mapped;
    }
    const copy = buf;
    return &copy;
}

fn unescapeQuotes(comptime s: []const u8) []const u8 {
    var buf: [s.len]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        buf[n] = s[i];
        n += 1;
        if (s[i] == '"' and i + 1 < s.len and s[i + 1] == '"') i += 1;
    }
    const copy = buf;
    return copy[0..n];
}

fn readField(comptime line: []const u8, index: *usize) []const u8 {
    if (index.* >= line.len) return "";
    if (line[index.*] == '"') {
        index.* += 1;
        const start = index.*;
        var escaped = false;
        while (index.* < line.len) {
            if (line[index.*] == '"') {
                if (index.* + 1 < line.len and line[index.* + 1] == '"') {
                    escaped = true;
                    index.* += 2;
                    continue;
                }
                const body = line[start..index.*];
                index.* += 1;
                if (index.* < line.len and line[index.*] == ',') index.* += 1;
                if (!escaped) return body;
                return unescapeQuotes(body);
            }
            index.* += 1;
        }
        @compileError("unterminated quote: " ++ line);
    }

    const start = index.*;
    while (index.* < line.len and line[index.*] != ',') index.* += 1;
    const body = std.mem.trim(u8, line[start..index.*], " \t\r");
    if (index.* < line.len and line[index.*] == ',') index.* += 1;
    return body;
}

fn helpText(comptime line: []const u8, index: usize) []const u8 {
    if (index >= line.len) return "";
    const rest = std.mem.trim(u8, line[index..], " \t\r");
    if (rest.len == 0 or rest[0] != '"') return rest;
    var cursor: usize = 0;
    return readField(rest, &cursor);
}

fn parseLine(comptime line: []const u8) ArgDef {
    var index: usize = 0;
    const short_s = readField(line, &index);
    const long = readField(line, &index);
    const type_name = readField(line, &index);
    const arity_s = readField(line, &index);
    const default_str = readField(line, &index);
    const help = helpText(line, index);

    if (short_s.len > 1) @compileError("short option must be one character: " ++ short_s);
    if (long.len == 0 and short_s.len == 0) @compileError("need a long or short name: " ++ line);
    if (type_name.len == 0) @compileError("missing type: " ++ line);

    const arity = parseArity(arity_s);
    const value_type = typeFromName(type_name);
    if (arity == .flag) {
        const bare = switch (@typeInfo(value_type)) {
            .optional => |opt| opt.child,
            else => value_type,
        };
        if (bare != bool) @compileError("arity 0 is a bool flag: " ++ line);
    }

    const name_src = if (long.len > 0) long else short_s;
    return .{
        .short = if (short_s.len == 1) short_s[0] else null,
        .long = long,
        .type_name = type_name,
        .arity = arity,
        .default_str = default_str,
        .help = help,
        .field_name = fieldNameFrom(name_src),
    };
}

fn rejectDuplicate(comptime prev: []const ArgDef, comptime def: ArgDef) void {
    for (prev) |old| {
        if (std.mem.eql(u8, old.field_name, def.field_name))
            @compileError("duplicate argument name: " ++ def.field_name);
        if (old.long.len > 0 and std.mem.eql(u8, old.long, def.long))
            @compileError("duplicate long option: " ++ def.long);
        if (old.short != null and def.short != null and old.short.? == def.short.?)
            @compileError("duplicate short option");
    }
}

/// Parse the comptime argument template. Pass `@embedFile("args.csv")`.
/// The first row is skipped when it starts with `short,`.
pub fn parseCsv(comptime csv: []const u8) []const ArgDef {
    const result = comptime blk: {
        @setEvalBranchQuota(200_000);
        var lines = std.mem.splitScalar(u8, csv, '\n');
        var defs: [max_defs]ArgDef = undefined;
        var count: usize = 0;
        var saw_header = false;

        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (!saw_header and std.mem.startsWith(u8, line, "short,")) {
                saw_header = true;
                continue;
            }
            if (count == defs.len) @compileError("too many arguments");
            const def = parseLine(line);
            rejectDuplicate(defs[0..count], def);
            defs[count] = def;
            count += 1;
        }

        const stored = defs[0..count].*;
        break :blk &stored;
    };
    return result;
}

// ---------------------------------------------------------------------------
// Type mapping
// ---------------------------------------------------------------------------

fn typeFromName(comptime name: []const u8) type {
    if (name.len > 1 and name[0] == '?') return ?typeFromName(name[1..]);
    if (std.mem.eql(u8, name, "bool")) return bool;
    if (std.mem.eql(u8, name, "u8")) return u8;
    if (std.mem.eql(u8, name, "u16")) return u16;
    if (std.mem.eql(u8, name, "u32")) return u32;
    if (std.mem.eql(u8, name, "u64")) return u64;
    if (std.mem.eql(u8, name, "usize")) return usize;
    if (std.mem.eql(u8, name, "i32")) return i32;
    if (std.mem.eql(u8, name, "i64")) return i64;
    if (std.mem.eql(u8, name, "[]const u8")) return []const u8;
    @compileError("unknown type: " ++ name);
}

fn isMulti(comptime def: ArgDef) bool {
    return def.arity == .one_or_more or def.arity == .zero_or_more;
}

fn resultFieldType(comptime def: ArgDef) type {
    const base = typeFromName(def.type_name);
    if (isMulti(def)) return []const base;
    return base;
}

fn parseScalar(comptime T: type, s: []const u8) Error!T {
    if (T == bool) {
        if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1")) return true;
        if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "0")) return false;
        return error.InvalidValue;
    }
    if (T == []const u8) return s;
    switch (@typeInfo(T)) {
        .int => return std.fmt.parseInt(T, s, 10) catch return error.InvalidValue,
        .optional => |opt| {
            if (s.len == 0 or std.mem.eql(u8, s, "null")) return null;
            return try parseScalar(opt.child, s);
        },
        else => @compileError("unsupported value type " ++ @typeName(T)),
    }
}

fn isOptionalType(comptime def: ArgDef) bool {
    return def.type_name.len > 0 and def.type_name[0] == '?';
}

/// Comma-separated items in a `+` or `*` default. Whitespace around each item
/// is ignored, and empty items are dropped. A blank cell is an empty list.
fn multiDefaultParts(comptime raw: []const u8) []const []const u8 {
    if (raw.len == 0) return &.{};
    const out = comptime blk: {
        var count: usize = 1;
        for (raw) |c| {
            if (c == ',') count += 1;
        }
        var parts: [count][]const u8 = undefined;
        var n: usize = 0;
        var start: usize = 0;
        for (raw, 0..) |c, i| {
            if (c == ',') {
                const piece = std.mem.trim(u8, raw[start..i], " \t");
                if (piece.len > 0) {
                    parts[n] = piece;
                    n += 1;
                }
                start = i + 1;
            }
        }
        const tail = std.mem.trim(u8, raw[start..], " \t");
        if (tail.len > 0) {
            parts[n] = tail;
            n += 1;
        }
        const stored = parts[0..n].*;
        break :blk stored;
    };
    return &out;
}

/// An option is required when omitting it would leave a non-optional value
/// without a default. `+` is a count, not a required flag: it is required
/// only when its default list is empty.
fn isRequired(comptime def: ArgDef) bool {
    if (def.arity == .flag or def.arity == .zero_or_more or isOptionalType(def)) return false;
    if (def.arity == .one_or_more) return multiDefaultParts(def.default_str).len == 0;
    if (std.mem.eql(u8, def.type_name, "[]const u8")) return false;
    return def.default_str.len == 0;
}

fn emptyDefault(comptime T: type) T {
    if (T == bool) return false;
    if (T == []const u8) return "";
    return switch (@typeInfo(T)) {
        .int => 0,
        .optional => null,
        else => @compileError("unsupported value type " ++ @typeName(T)),
    };
}

fn parseDefault(comptime def: ArgDef) resultFieldType(def) {
    const T = resultFieldType(def);
    if (isMulti(def)) {
        const parts = multiDefaultParts(def.default_str);
        if (parts.len == 0) return @as(T, &.{});
        const Base = typeFromName(def.type_name);
        var values: [parts.len]Base = undefined;
        for (parts, 0..) |part, i| {
            values[i] = parseScalar(Base, part) catch
                @compileError("bad default for " ++ def.field_name ++ ": " ++ part);
        }
        const copy = values;
        return &copy;
    }
    if (def.arity == .flag and def.default_str.len == 0) {
        if (@typeInfo(T) == .optional) return null;
        return false;
    }
    if (@typeInfo(T) == .optional) {
        const s = def.default_str;
        if (s.len == 0 or std.mem.eql(u8, s, "null")) return null;
    }
    if (isRequired(def)) return emptyDefault(T);
    return parseScalar(T, def.default_str) catch
        @compileError("bad default for " ++ def.field_name ++ ": " ++ def.default_str);
}

fn defaultPtr(comptime value: anytype) *const anyopaque {
    return @ptrCast(&value);
}

// ---------------------------------------------------------------------------
// Generate the Result struct
// ---------------------------------------------------------------------------

pub fn makeResultType(comptime defs: []const ArgDef) type {
    const n = defs.len;
    if (n == 0) return struct {};

    var field_names: [n][]const u8 = undefined;
    var field_types: [n]type = undefined;
    var field_attrs: [n]std.lang.Type.Struct.FieldAttributes = @splat(.{});

    inline for (defs, 0..) |def, i| {
        const T = resultFieldType(def);
        field_names[i] = def.field_name;
        field_types[i] = T;
        field_attrs[i] = .{
            .default_value_ptr = defaultPtr(parseDefault(def)),
            .@"align" = @alignOf(T),
        };
    }

    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

// ---------------------------------------------------------------------------
// Runtime parser
// ---------------------------------------------------------------------------

fn BucketArray(comptime n: usize) type {
    return [n]std.ArrayList([]const u8);
}

fn looksLikeOption(arg: []const u8) bool {
    return arg.len > 1 and arg[0] == '-';
}

/// For `+` and `*`, take `first` (an `=` or attached value) and then every
/// argument that follows until the next option. `--` ends option parsing and
/// the remaining tokens belong to this option, including names that start
/// with `-`.
fn takeMulti(
    allocator: std.mem.Allocator,
    result: anytype,
    buckets: anytype,
    seen: []bool,
    comptime def: ArgDef,
    comptime idx: usize,
    argv: []const []const u8,
    i: usize,
    first: ?[]const u8,
) !usize {
    var count: usize = 0;
    if (first) |value| {
        try assign(allocator, result, buckets, seen, def, idx, value);
        count += 1;
    }

    var next = i + 1;
    while (next < argv.len) {
        const arg = argv[next];
        if (std.mem.eql(u8, arg, "--")) {
            next += 1;
            while (next < argv.len) : (next += 1) {
                try assign(allocator, result, buckets, seen, def, idx, argv[next]);
                count += 1;
            }
            break;
        }
        if (looksLikeOption(arg)) break;
        try assign(allocator, result, buckets, seen, def, idx, arg);
        count += 1;
        next += 1;
    }

    if (count == 0 and def.arity == .one_or_more) {
        diagnostic("missing value for --{s}\n", .{def.long});
        return error.MissingValue;
    }
    return next;
}

fn assign(
    allocator: std.mem.Allocator,
    result: anytype,
    buckets: anytype,
    seen: []bool,
    comptime def: ArgDef,
    comptime idx: usize,
    value: []const u8,
) !void {
    if (comptime isMulti(def)) {
        try buckets[idx].append(allocator, value);
        return;
    }
    @field(result, def.field_name) = parseScalar(resultFieldType(def), value) catch {
        diagnostic("invalid value for --{s}: {s}\n", .{ def.long, value });
        return error.InvalidValue;
    };
    seen[idx] = true;
}

fn consumeLong(
    comptime defs: []const ArgDef,
    allocator: std.mem.Allocator,
    result: anytype,
    buckets: anytype,
    seen: []bool,
    argv: []const []const u8,
    i: usize,
) !usize {
    const body = argv[i][2..];
    const eq = std.mem.indexOfScalar(u8, body, '=');
    const name = if (eq) |e| body[0..e] else body;
    const inline_val: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;

    inline for (defs, 0..) |def, idx| {
        if (def.long.len != 0 and std.mem.eql(u8, def.long, name)) {
            if (comptime def.arity == .flag) {
                if (inline_val != null) {
                    diagnostic("unexpected value for --{s}\n", .{name});
                    return error.UnexpectedValue;
                }
                @field(result, def.field_name) = true;
                return i + 1;
            } else if (comptime isMulti(def)) {
                return try takeMulti(allocator, result, buckets, seen, def, idx, argv, i, inline_val);
            } else {
                const value = inline_val orelse blk: {
                    if (i + 1 >= argv.len) {
                        diagnostic("missing value for --{s}\n", .{name});
                        return error.MissingValue;
                    }
                    break :blk argv[i + 1];
                };
                try assign(allocator, result, buckets, seen, def, idx, value);
                return i + if (inline_val == null) @as(usize, 2) else 1;
            }
        }
    }

    if (std.mem.eql(u8, name, "help")) return error.Help;
    diagnostic("unknown option --{s}\n", .{name});
    return error.UnknownOption;
}

/// `null` means this short was a flag and the cluster continues.
/// A number is the next argv index after a value was taken.
fn applyShort(
    comptime defs: []const ArgDef,
    allocator: std.mem.Allocator,
    result: anytype,
    buckets: anytype,
    seen: []bool,
    argv: []const []const u8,
    i: usize,
    cluster: []const u8,
    c: usize,
    ch: u8,
) !?usize {
    inline for (defs, 0..) |def, idx| {
        if (def.short) |s| {
            if (s == ch) {
                if (comptime def.arity == .flag) {
                    @field(result, def.field_name) = true;
                    return null;
                } else if (comptime isMulti(def)) {
                    const attached: ?[]const u8 = if (c + 1 < cluster.len) cluster[c + 1 ..] else null;
                    return try takeMulti(allocator, result, buckets, seen, def, idx, argv, i, attached);
                } else if (c + 1 < cluster.len) {
                    try assign(allocator, result, buckets, seen, def, idx, cluster[c + 1 ..]);
                    return i + 1;
                } else if (i + 1 >= argv.len) {
                    diagnostic("missing value for -{c}\n", .{ch});
                    return error.MissingValue;
                } else {
                    try assign(allocator, result, buckets, seen, def, idx, argv[i + 1]);
                    return i + 2;
                }
            }
        }
    }
    if (ch == 'h') return error.Help;
    diagnostic("unknown option -{c}\n", .{ch});
    return error.UnknownOption;
}

fn consumeShort(
    comptime defs: []const ArgDef,
    allocator: std.mem.Allocator,
    result: anytype,
    buckets: anytype,
    seen: []bool,
    argv: []const []const u8,
    i: usize,
) !usize {
    const cluster = argv[i][1..];
    var c: usize = 0;
    while (c < cluster.len) {
        if (try applyShort(defs, allocator, result, buckets, seen, argv, i, cluster, c, cluster[c])) |next|
            return next;
        c += 1;
    }
    return i + 1;
}

fn reportMissing(comptime def: ArgDef) Error {
    if (def.long.len > 0) {
        diagnostic("missing argument --{s}\n", .{def.long});
    } else {
        diagnostic("missing argument -{c}\n", .{def.short.?});
    }
    return error.MissingArgument;
}

fn finishMultis(
    comptime defs: []const ArgDef,
    allocator: std.mem.Allocator,
    result: anytype,
    buckets: anytype,
    seen: []const bool,
) !void {
    inline for (defs, 0..) |def, idx| {
        if (comptime isRequired(def)) {
            const provided = if (comptime isMulti(def)) buckets[idx].items.len != 0 else seen[idx];
            if (!provided) return reportMissing(def);
        }
    }

    inline for (defs, 0..) |def, idx| {
        if (comptime isMulti(def)) {
            const raw = buckets[idx].items;
            const Base = typeFromName(def.type_name);
            if (raw.len == 0) {
                const parts = comptime multiDefaultParts(def.default_str);
                if (parts.len != 0) {
                    const out = try allocator.alloc(Base, parts.len);
                    errdefer allocator.free(out);
                    for (parts, 0..) |part, j| {
                        out[j] = parseScalar(Base, part) catch {
                            diagnostic("invalid value for --{s}: {s}\n", .{ def.long, part });
                            return error.InvalidValue;
                        };
                    }
                    @field(result, def.field_name) = out;
                }
            } else {
                const out = try allocator.alloc(Base, raw.len);
                errdefer allocator.free(out);
                for (raw, 0..) |item, j| {
                    out[j] = parseScalar(Base, item) catch {
                        diagnostic("invalid value for --{s}: {s}\n", .{ def.long, item });
                        return error.InvalidValue;
                    };
                }
                @field(result, def.field_name) = out;
            }
        }
    }
}

/// Parse `argv` (`argv[0]` is the program name).
///
/// String values point at `argv` and stay valid only as long as `argv` does.
/// `+` and `*` options take each argument that follows until the next option.
/// Those slices are owned, including a copy of a schema default list: free
/// them with `deinit`. An option is required when it has no default.
/// `-h` and `--help` return `error.Help` unless the schema defines that option.
pub fn parse(
    comptime defs: []const ArgDef,
    comptime Result: type,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) (Error || std.mem.Allocator.Error)!Result {
    var result: Result = .{};
    var buckets: BucketArray(defs.len) = undefined;
    for (&buckets) |*bucket| bucket.* = .empty;
    defer for (&buckets) |*bucket| bucket.deinit(allocator);
    var seen: [defs.len]bool = @splat(false);

    var i: usize = 1;
    while (i < argv.len) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            if (i < argv.len) {
                diagnostic("unexpected positional: {s}\n", .{argv[i]});
                return error.UnexpectedPositional;
            }
            break;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            i = try consumeLong(defs, allocator, &result, &buckets, &seen, argv, i);
        } else if (arg.len > 1 and arg[0] == '-') {
            i = try consumeShort(defs, allocator, &result, &buckets, &seen, argv, i);
        } else {
            diagnostic("unexpected positional: {s}\n", .{arg});
            return error.UnexpectedPositional;
        }
    }

    try finishMultis(defs, allocator, &result, &buckets, &seen);
    return result;
}

/// Free slices owned by a result from `parse`. String bytes themselves are not
/// copied, so only the repeated-option arrays are released. Schema default
/// lists are copied during `parse`; a bare `Result{}` still points at the
/// template and must not be passed here.
pub fn deinit(comptime defs: []const ArgDef, allocator: std.mem.Allocator, result: anytype) void {
    inline for (defs) |def| {
        if (comptime isMulti(def)) {
            const slice = @field(result, def.field_name);
            const preset = comptime parseDefault(def);
            if (slice.ptr != preset.ptr) allocator.free(slice);
        }
    }
}

// ---------------------------------------------------------------------------
// Help
// ---------------------------------------------------------------------------

fn schemaHasHelp(comptime defs: []const ArgDef) bool {
    for (defs) |def| {
        if (std.mem.eql(u8, def.long, "help")) return true;
        if (def.short) |s| if (s == 'h') return true;
    }
    return false;
}

/// Value word used in help. `[]const u8` reads as `text`; a leading `?` is dropped.
fn typeWord(comptime type_name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, type_name, "[]const u8")) return "text";
    if (type_name.len > 0 and type_name[0] == '?') return type_name[1..];
    return type_name;
}

/// `""`, `" <text>"`, or `" <text...>"`.
fn valueHint(comptime def: ArgDef) []const u8 {
    const result = comptime blk: {
        if (def.arity == .flag) break :blk "";
        const word = typeWord(def.type_name);
        if (def.arity == .one) break :blk " <" ++ word ++ ">";
        break :blk " <" ++ word ++ "...>";
    };
    return result;
}

fn optionLabel(comptime def: ArgDef) []const u8 {
    const result = comptime blk: {
        const hint = valueHint(def);
        if (def.short) |s| {
            const flag = &[2]u8{ '-', s };
            if (def.long.len > 0) break :blk flag ++ ", --" ++ def.long ++ hint;
            break :blk flag ++ hint;
        }
        // Four spaces so `--` lines up with `-x, --name`.
        break :blk "    --" ++ def.long ++ hint;
    };
    return result;
}

fn defaultLabel(comptime def: ArgDef) []const u8 {
    if (isRequired(def)) return "required";
    if (isMulti(def)) {
        const joined = comptime blk: {
            const parts = multiDefaultParts(def.default_str);
            if (parts.len == 0) break :blk "none";
            var text: []const u8 = parts[0];
            for (parts[1..]) |part| text = text ++ ", " ++ part;
            break :blk text;
        };
        return joined;
    }
    const optional = isOptionalType(def);
    const bare = if (optional) def.type_name[1..] else def.type_name;
    const s = def.default_str;
    if (std.mem.eql(u8, bare, "[]const u8")) {
        if (optional and (s.len == 0 or std.mem.eql(u8, s, "null"))) return "none";
        if (s.len == 0) return "\"\"";
        return s;
    }
    if (s.len == 0 or std.mem.eql(u8, s, "null")) return "none";
    return s;
}

fn usageAtom(comptime def: ArgDef) []const u8 {
    const result = comptime blk: {
        const hint = valueHint(def);
        if (def.short) |s| break :blk &[2]u8{ '-', s } ++ hint;
        break :blk "--" ++ def.long ++ hint;
    };
    return result;
}

/// Required options, then `[options]` when anything is optional (including built-in help).
fn usageSuffix(comptime defs: []const ArgDef) []const u8 {
    const out = comptime blk: {
        var text: []const u8 = "";
        var rest = !schemaHasHelp(defs);
        var wrote = false;
        for (defs) |def| {
            if (isRequired(def)) {
                const atom = usageAtom(def);
                text = if (wrote) text ++ " " ++ atom else atom;
                wrote = true;
            } else rest = true;
        }
        if (rest) text = if (wrote) text ++ " [options]" else text ++ "[options]";
        break :blk text;
    };
    return out;
}

const HelpWidths = struct { option: usize, default: usize };

fn helpWidths(comptime defs: []const ArgDef) HelpWidths {
    var option: usize = "option".len;
    var default: usize = "default".len;
    inline for (defs) |def| {
        option = @max(option, optionLabel(def).len);
        default = @max(default, defaultLabel(def).len);
    }
    if (!schemaHasHelp(defs)) option = @max(option, "-h, --help".len);
    return .{ .option = option, .default = default };
}

/// Print a help table to stderr.
///
/// `program` is `argv[0]`; only its file name is shown. Options with no
/// default are required: they appear in the usage line and again first, with
/// `required` in the default column. Every other option shows the default it
/// compiles to (`none` for null or an empty list).
pub fn printHelp(comptime defs: []const ArgDef, program: []const u8) void {
    const widths = comptime helpWidths(defs);
    const row_fmt = comptime std.fmt.comptimePrint(
        "  {{s: <{d}}}   {{s: <{d}}}   {{s}}\n",
        .{ widths.option, widths.default },
    );
    const suffix = comptime usageSuffix(defs);
    const base = std.fs.path.basename(program);
    const name = if (base.len == 0) "program" else base;

    std.debug.print("Usage\n", .{});
    if (suffix.len == 0) {
        std.debug.print("  {s}\n\n", .{name});
    } else {
        std.debug.print("  {s} {s}\n\n", .{ name, suffix });
    }
    std.debug.print(row_fmt, .{ "option", "default", "description" });

    const split = comptime blk: {
        var required = false;
        var rest = !schemaHasHelp(defs);
        for (defs) |def| {
            if (isRequired(def)) required = true else rest = true;
        }
        break :blk .{ .required = required, .rest = rest };
    };
    inline for (defs) |def| {
        if (comptime isRequired(def)) {
            std.debug.print(row_fmt, .{
                comptime optionLabel(def),
                comptime defaultLabel(def),
                def.help,
            });
        }
    }
    if (split.required and split.rest) std.debug.print("\n", .{});
    inline for (defs) |def| {
        if (comptime !isRequired(def)) {
            std.debug.print(row_fmt, .{
                comptime optionLabel(def),
                comptime defaultLabel(def),
                def.help,
            });
        }
    }
    if (comptime !schemaHasHelp(defs)) {
        std.debug.print(row_fmt, .{ "-h, --help", "", "Show this help" });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const example_defs = parseCsv(@embedFile("args.csv"));

test "embedded args.csv is the argument template" {
    try std.testing.expectEqual(@as(usize, 5), example_defs.len);
    try std.testing.expectEqualStrings("verbose", example_defs[0].field_name);
    try std.testing.expectEqualStrings("port", example_defs[2].field_name);
    try std.testing.expectEqual(Arity.one, example_defs[2].arity);
    try std.testing.expectEqualStrings("8080", example_defs[2].default_str);
    try std.testing.expectEqualStrings("file", example_defs[4].field_name);
    try std.testing.expectEqual(Arity.one_or_more, example_defs[4].arity);
}

test "commas and escaped quotes belong to help or the default" {
    const defs = comptime parseCsv(
        \\short,long,type,arity,default,help
        \\v,verbose,bool,0,false,"Be loud, please"
        \\n,name,[]const u8,1,"say ""hi""",Greeting, with comma
    );
    try std.testing.expectEqualStrings("Be loud, please", defs[0].help);
    try std.testing.expectEqualStrings("say \"hi\"", defs[1].default_str);
    try std.testing.expectEqualStrings("Greeting, with comma", defs[1].help);
    try std.testing.expectEqualStrings("dry_run", comptime fieldNameFrom("dry-run"));
}

test "defaults come from the schema" {
    const defs = example_defs;
    const Result = makeResultType(defs);
    const args: Result = .{};
    try std.testing.expectEqual(false, args.verbose);
    try std.testing.expectEqual(false, args.backup);
    try std.testing.expectEqual(@as(u16, 8080), args.port);
    try std.testing.expect(args.output == null);
    try std.testing.expectEqual(@as(usize, 0), args.file.len);
}

test "parse flags, strings, integers, and repeated options" {
    const defs = example_defs;
    const Result = makeResultType(defs);
    const allocator = std.testing.allocator;
    const args = try parse(defs, Result, allocator, &.{
        "prog",
        "-vb",
        "--port=9000",
        "--output",
        "out.txt",
        "-f",
        "a.txt",
        "b.txt",
    });
    defer deinit(defs, allocator, args);

    try std.testing.expectEqual(true, args.verbose);
    try std.testing.expectEqual(true, args.backup);
    try std.testing.expectEqual(@as(u16, 9000), args.port);
    try std.testing.expectEqualStrings("out.txt", args.output.?);
    try std.testing.expectEqual(@as(usize, 2), args.file.len);
    try std.testing.expectEqualStrings("a.txt", args.file[0]);
    try std.testing.expectEqualStrings("b.txt", args.file[1]);
}

test "string values and attached short values" {
    const defs = comptime parseCsv(
        \\short,long,type,arity,default,help
        \\n,name,[]const u8,1,world,Name
        \\c,count,i32,1,-1,Count
        \\,dry-run,bool,0,false,Do not write
        \\t,tag,u8,*,,Tags
    );
    const Result = makeResultType(defs);
    const allocator = std.testing.allocator;
    const args = try parse(defs, Result, allocator, &.{
        "prog",
        "-nzig",
        "--count",
        "4",
        "--dry-run",
        "--tag",
        "1",
        "2",
    });
    defer deinit(defs, allocator, args);

    try std.testing.expectEqualStrings("zig", args.name);
    try std.testing.expectEqual(@as(i32, 4), args.count);
    try std.testing.expectEqual(true, args.dry_run);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, args.tag);
}

test "zero or more may be empty, and a string default is kept" {
    const defs = comptime parseCsv(
        \\n,name,[]const u8,1,world,Name
        \\t,tag,u8,*,,Tags
    );
    const Result = makeResultType(defs);
    const allocator = std.testing.allocator;
    const args = try parse(defs, Result, allocator, &.{"prog"});
    defer deinit(defs, allocator, args);
    try std.testing.expectEqualStrings("world", args.name);
    try std.testing.expectEqual(@as(usize, 0), args.tag.len);
}

test "multi options stop at the next option" {
    const defs = example_defs;
    const Result = makeResultType(defs);
    const allocator = std.testing.allocator;
    const args = try parse(defs, Result, allocator, &.{
        "prog",
        "-f",
        "a.txt",
        "b.txt",
        "c.txt",
        "--port",
        "7",
        "--output",
        "out.txt",
    });
    defer deinit(defs, allocator, args);

    try std.testing.expectEqual(@as(u16, 7), args.port);
    try std.testing.expectEqualStrings("out.txt", args.output.?);
    try std.testing.expectEqual(@as(usize, 3), args.file.len);
    try std.testing.expectEqualStrings("a.txt", args.file[0]);
    try std.testing.expectEqualStrings("b.txt", args.file[1]);
    try std.testing.expectEqualStrings("c.txt", args.file[2]);

    const dashed = try parse(defs, Result, allocator, &.{
        "prog",
        "--file",
        "plain.txt",
        "--",
        "-odd.txt",
    });
    defer deinit(defs, allocator, dashed);
    try std.testing.expectEqual(@as(usize, 2), dashed.file.len);
    try std.testing.expectEqualStrings("plain.txt", dashed.file[0]);
    try std.testing.expectEqualStrings("-odd.txt", dashed.file[1]);

    const attached = try parse(defs, Result, allocator, &.{
        "prog",
        "--file=a.txt",
        "b.txt",
    });
    defer deinit(defs, allocator, attached);
    try std.testing.expectEqualStrings("a.txt", attached.file[0]);
    try std.testing.expectEqualStrings("b.txt", attached.file[1]);
}

test "errors for unknown, missing, invalid, positional, and help" {
    const defs = example_defs;
    const Result = makeResultType(defs);
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnknownOption, parse(defs, Result, allocator, &.{ "prog", "--nope" }));
    try std.testing.expectError(error.MissingValue, parse(defs, Result, allocator, &.{ "prog", "--port" }));
    try std.testing.expectError(error.InvalidValue, parse(defs, Result, allocator, &.{ "prog", "--port", "nope" }));
    try std.testing.expectError(error.UnexpectedPositional, parse(defs, Result, allocator, &.{ "prog", "extra" }));
    try std.testing.expectError(error.MissingArgument, parse(defs, Result, allocator, &.{"prog"}));
    try std.testing.expectError(error.Help, parse(defs, Result, allocator, &.{ "prog", "--help" }));
    try std.testing.expectError(error.Help, parse(defs, Result, allocator, &.{ "prog", "-h" }));
    try std.testing.expectError(error.UnexpectedValue, parse(defs, Result, allocator, &.{ "prog", "--verbose=true" }));
}

test "help labels show defaults and mark required options" {
    try std.testing.expectEqualStrings("-v, --verbose", optionLabel(example_defs[0]));
    try std.testing.expectEqualStrings("false", defaultLabel(example_defs[0]));
    try std.testing.expectEqualStrings("-b, --backup", optionLabel(example_defs[1]));
    try std.testing.expectEqualStrings("false", defaultLabel(example_defs[1]));
    try std.testing.expectEqualStrings("-p, --port <u16>", optionLabel(example_defs[2]));
    try std.testing.expectEqualStrings("8080", defaultLabel(example_defs[2]));
    try std.testing.expectEqualStrings("-o, --output <text>", optionLabel(example_defs[3]));
    try std.testing.expectEqualStrings("none", defaultLabel(example_defs[3]));
    try std.testing.expectEqualStrings("-f, --file <text...>", optionLabel(example_defs[4]));
    try std.testing.expectEqualStrings("required", defaultLabel(example_defs[4]));
    try std.testing.expectEqualStrings("-f <text...> [options]", usageSuffix(example_defs));
    try std.testing.expectEqual(@as(usize, 20), helpWidths(example_defs).option);
    try std.testing.expectEqual(@as(usize, 8), helpWidths(example_defs).default);

    const defs = comptime parseCsv(
        \\short,long,type,arity,default,help
        \\n,name,[]const u8,1,world,Name
        \\,dry-run,bool,0,false,Do not write
        \\t,tag,u8,*,,Tags
        \\x,,i32,1,-1,Short only
        \\e,empty,[]const u8,1,,Empty text
        \\o,output,?[]const u8,1,out.txt,Output
        \\p,port,?u16,1,null,Optional port
        \\q,quiet,bool,0,true,Start quiet
        \\f,file,[]const u8,+,,Files
        \\,also,[]const u8,+,,More files
    );
    try std.testing.expectEqualStrings("-n, --name <text>", optionLabel(defs[0]));
    try std.testing.expectEqualStrings("world", defaultLabel(defs[0]));
    try std.testing.expectEqualStrings("    --dry-run", optionLabel(defs[1]));
    try std.testing.expectEqualStrings("-t, --tag <u8...>", optionLabel(defs[2]));
    try std.testing.expectEqualStrings("none", defaultLabel(defs[2]));
    try std.testing.expectEqualStrings("-x <i32>", optionLabel(defs[3]));
    try std.testing.expectEqualStrings("-1", defaultLabel(defs[3]));
    try std.testing.expectEqualStrings("\"\"", defaultLabel(defs[4]));
    try std.testing.expectEqualStrings("out.txt", defaultLabel(defs[5]));
    try std.testing.expectEqualStrings("-p, --port <u16>", optionLabel(defs[6]));
    try std.testing.expectEqualStrings("none", defaultLabel(defs[6]));
    try std.testing.expectEqualStrings("true", defaultLabel(defs[7]));
    try std.testing.expectEqualStrings("-f <text...> --also <text...> [options]", usageSuffix(defs));

    const optional_only = comptime parseCsv("v,verbose,bool,0,false,Loud\n");
    try std.testing.expectEqualStrings("[options]", usageSuffix(optional_only));

    const with_help = comptime parseCsv("h,help,bool,0,false,Show this help\n");
    try std.testing.expect(schemaHasHelp(with_help));
    try std.testing.expectEqualStrings("-h, --help", optionLabel(with_help[0]));
    try std.testing.expectEqualStrings("false", defaultLabel(with_help[0]));
    try std.testing.expectEqualStrings("[options]", usageSuffix(with_help));
}

test "defaults decide required options, and + accepts a list" {
    const defs = comptime parseCsv(
        \\short,long,type,arity,default,help
        \\p,port,u16,1,,Listen port
        \\o,output,?[]const u8,1,,Optional output
        \\n,name,?[]const u8,1,null,Also optional
        \\c,count,i32,1,3,Count
        \\f,file,[]const u8,+,"a.txt, b.txt",Input files
        \\t,tag,u8,*,"1,2",Tags
        \\e,extra,[]const u8,+,one,One default
    );
    try std.testing.expect(isRequired(defs[0]));
    try std.testing.expect(!isRequired(defs[1]));
    try std.testing.expect(!isRequired(defs[2]));
    try std.testing.expect(!isRequired(defs[3]));
    try std.testing.expect(!isRequired(defs[4]));
    try std.testing.expect(!isRequired(defs[5]));
    try std.testing.expect(!isRequired(defs[6]));
    try std.testing.expectEqualStrings("required", defaultLabel(defs[0]));
    try std.testing.expectEqualStrings("none", defaultLabel(defs[1]));
    try std.testing.expectEqualStrings("none", defaultLabel(defs[2]));
    try std.testing.expectEqualStrings("3", defaultLabel(defs[3]));
    try std.testing.expectEqualStrings("a.txt, b.txt", defaultLabel(defs[4]));
    try std.testing.expectEqualStrings("1, 2", defaultLabel(defs[5]));
    try std.testing.expectEqualStrings("one", defaultLabel(defs[6]));
    try std.testing.expectEqualStrings("-p <u16> [options]", usageSuffix(defs));

    const Result = makeResultType(defs);
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingArgument, parse(defs, Result, allocator, &.{"prog"}));

    const args = try parse(defs, Result, allocator, &.{ "prog", "--port", "9" });
    defer deinit(defs, allocator, args);
    try std.testing.expectEqual(@as(u16, 9), args.port);
    try std.testing.expect(args.output == null);
    try std.testing.expect(args.name == null);
    try std.testing.expectEqual(@as(i32, 3), args.count);
    try std.testing.expectEqual(@as(usize, 2), args.file.len);
    try std.testing.expectEqualStrings("a.txt", args.file[0]);
    try std.testing.expectEqualStrings("b.txt", args.file[1]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, args.tag);
    try std.testing.expectEqualStrings("one", args.extra[0]);

    const replaced = try parse(defs, Result, allocator, &.{
        "prog",
        "-p",
        "4",
        "-f",
        "c.txt",
        "d.txt",
    });
    defer deinit(defs, allocator, replaced);
    try std.testing.expectEqual(@as(u16, 4), replaced.port);
    try std.testing.expectEqual(@as(usize, 2), replaced.file.len);
    try std.testing.expectEqualStrings("c.txt", replaced.file[0]);
    try std.testing.expectEqualStrings("d.txt", replaced.file[1]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, replaced.tag);
}

test "a schema-defined -h is a normal flag" {
    const defs = comptime parseCsv("h,hello,bool,0,false,Say hello\n");
    const Result = makeResultType(defs);
    const allocator = std.testing.allocator;
    const args = try parse(defs, Result, allocator, &.{ "prog", "-h" });
    defer deinit(defs, allocator, args);
    try std.testing.expectEqual(true, args.hello);
}
