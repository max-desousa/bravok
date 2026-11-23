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
/// or `null` is null. A non-optional type with a default is not required. A
/// blank cell on a non-optional number, bool, or `[]const u8` is required.
/// For `+` and `*`, `default` is a comma-separated list (`a.txt,b.txt`);
/// quote that cell when it contains a comma. A `?` on `+` or `*` makes the
/// list optional: blank or `null` is null, and each item uses the inner type.
/// `+` with no items is required. `*` with no items is an empty list, or null
/// when the list is optional.
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
    UnknownCommand,
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

fn multiElementType(comptime def: ArgDef) type {
    const declared = typeFromName(def.type_name);
    return switch (@typeInfo(declared)) {
        .optional => |opt| opt.child,
        else => declared,
    };
}

fn resultFieldType(comptime def: ArgDef) type {
    if (!isMulti(def)) return typeFromName(def.type_name);
    const list = []const multiElementType(def);
    if (isOptionalType(def)) return ?list;
    return list;
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

/// Items of a `+` or `*` default. On an optional list, a blank cell or `null`
/// means the list itself is null, not a list of one null item.
fn listedDefaults(comptime def: ArgDef) []const []const u8 {
    if (isOptionalType(def)) {
        const s = def.default_str;
        if (s.len == 0 or std.mem.eql(u8, s, "null")) return &.{};
    }
    return multiDefaultParts(def.default_str);
}

/// An option is required when omitting it would leave a non-optional value
/// without a default. A blank cell is no default for a number, a bool, or
/// `[]const u8`. `+` is a count, not a required flag: it is required only
/// when its default list is empty.
fn isRequired(comptime def: ArgDef) bool {
    if (def.arity == .flag or def.arity == .zero_or_more or isOptionalType(def)) return false;
    if (def.arity == .one_or_more) return listedDefaults(def).len == 0;
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
        const parts = listedDefaults(def);
        const Base = multiElementType(def);
        if (parts.len == 0) {
            if (comptime isOptionalType(def)) return null;
            return @as(T, &.{});
        }
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

fn findSub(comptime subs: []const SubDef, arg: []const u8) ?usize {
    comptime var index: usize = 0;
    inline while (index < subs.len) : (index += 1) {
        if (std.mem.eql(u8, arg, subs[index].long)) return index;
    }
    return null;
}

/// For `+` and `*`, take `first` (an `=` or attached value) and then every
/// argument that follows until the next option or subcommand. `--` ends
/// option parsing and the remaining tokens belong to this option, including
/// names that start with `-`.
fn takeMulti(
    allocator: std.mem.Allocator,
    result: anytype,
    buckets: anytype,
    seen: []bool,
    comptime subs: []const SubDef,
    comptime def: ArgDef,
    comptime idx: usize,
    argv: []const []const u8,
    i: usize,
    first: ?[]const u8,
) !usize {
    seen[idx] = true;
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
        if (looksLikeOption(arg) or findSub(subs, arg) != null) break;
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
    comptime subs: []const SubDef,
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
                return try takeMulti(allocator, result, buckets, seen, subs, def, idx, argv, i, inline_val);
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
    comptime subs: []const SubDef,
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
                    return try takeMulti(allocator, result, buckets, seen, subs, def, idx, argv, i, attached);
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
    comptime subs: []const SubDef,
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
        if (try applyShort(defs, subs, allocator, result, buckets, seen, argv, i, cluster, c, cluster[c])) |next|
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
            const Base = multiElementType(def);
            if (raw.len == 0) {
                if (seen[idx]) {
                    @field(result, def.field_name) = @as([]const Base, &.{});
                } else {
                    const parts = comptime listedDefaults(def);
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

const Scan = struct { next: usize, sub: ?usize };

/// Parse options starting at `start`. Stops before a subcommand word, which
/// is returned in `sub` and left unconsumed (`next` is the index after it).
fn scanOptions(
    comptime defs: []const ArgDef,
    comptime subs: []const SubDef,
    allocator: std.mem.Allocator,
    result: anytype,
    buckets: anytype,
    seen: []bool,
    argv: []const []const u8,
    start: usize,
) !Scan {
    var i = start;
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
            i = try consumeLong(defs, subs, allocator, result, buckets, seen, argv, i);
        } else if (arg.len > 1 and arg[0] == '-') {
            i = try consumeShort(defs, subs, allocator, result, buckets, seen, argv, i);
        } else if (findSub(subs, arg)) |sub| {
            return .{ .next = i + 1, .sub = sub };
        } else if (subs.len != 0) {
            diagnostic("unknown subcommand: {s}\n", .{arg});
            return error.UnknownCommand;
        } else {
            diagnostic("unexpected positional: {s}\n", .{arg});
            return error.UnexpectedPositional;
        }
    }
    return .{ .next = i, .sub = null };
}

/// Parse `argv` (`argv[0]` is the program name).
///
/// String values point at `argv` and stay valid only as long as `argv` does.
/// `+` and `*` options take each argument that follows until the next option.
/// Those slices are owned, including a copy of a schema default list: free
/// them with `deinit`. An option is required when it has no default.
/// `-h` and `--help` return `error.Help` unless the schema defines that option.
fn parseArgs(
    comptime defs: []const ArgDef,
    comptime Result: type,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) (Error || std.mem.Allocator.Error)!Result {
    const none: [0]SubDef = .{};
    var result: Result = .{};
    var buckets: BucketArray(defs.len) = undefined;
    for (&buckets) |*bucket| bucket.* = .empty;
    defer for (&buckets) |*bucket| bucket.deinit(allocator);
    var seen: [defs.len]bool = @splat(false);

    _ = try scanOptions(defs, &none, allocator, &result, &buckets, &seen, argv, 1);
    try finishMultis(defs, allocator, &result, &buckets, &seen);
    return result;
}

/// Free slices owned by a result from `parse`. String bytes themselves are not
/// copied, so only the repeated-option arrays are released. Schema default
/// lists are copied during `parse`; a bare `Result{}` still points at the
/// template and must not be passed here.
fn deinitArgs(comptime defs: []const ArgDef, allocator: std.mem.Allocator, result: anytype) void {
    inline for (defs) |def| {
        if (comptime isMulti(def)) {
            if (comptime isOptionalType(def)) {
                const field = @field(result, def.field_name);
                if (field) |slice| {
                    const preset = comptime parseDefault(def);
                    if (preset == null or slice.ptr != preset.?.ptr) allocator.free(slice);
                }
            } else {
                const slice = @field(result, def.field_name);
                const preset = comptime parseDefault(def);
                if (slice.ptr != preset.ptr) allocator.free(slice);
            }
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
            const parts = listedDefaults(def);
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
    std.debug.print("Usage\n", .{});
    printUsageLine(programName(program), "", comptime usageSuffix(defs));
    std.debug.print("\n", .{});
    writeOptionTable(defs);
}

fn programName(program: []const u8) []const u8 {
    const base = std.fs.path.basename(program);
    return if (base.len == 0) "program" else base;
}

/// `words` is the command path already taken (`remote sync`). `suffix` is
/// this level's required options, `[options]`, and `[command]` when this
/// level has subcommands.
fn printUsageLine(name: []const u8, comptime words: []const u8, comptime suffix: []const u8) void {
    if (words.len == 0 and suffix.len == 0) {
        std.debug.print("  {s}\n", .{name});
    } else if (words.len == 0) {
        std.debug.print("  {s} {s}\n", .{ name, suffix });
    } else if (suffix.len == 0) {
        std.debug.print("  {s} {s}\n", .{ name, words });
    } else {
        std.debug.print("  {s} {s} {s}\n", .{ name, words, suffix });
    }
}

fn writeOptionTable(comptime defs: []const ArgDef) void {
    const widths = comptime helpWidths(defs);
    const row_fmt = comptime std.fmt.comptimePrint(
        "  {{s: <{d}}}   {{s: <{d}}}   {{s}}\n",
        .{ widths.option, widths.default },
    );
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
// Subcommands
// ---------------------------------------------------------------------------

/// Safety stop for nested `sub.csv` files. Real command lines are much
/// shallower. A short `path` mask keeps each directory name small, so this
/// cap is reached before an operating-system path limit.
pub const max_command_depth = 64;

const max_segment_len = 255;
const max_schema_path = 4096;

/// Prefix passed to `embed`. The package build maps the `args` option onto
/// this prefix, so the directory the user points at contains `args.csv`
/// directly. Its own folder name is not part of the layout.
const command_root = "args/";

/// One row of a `sub.csv`. `path` is the directory under the parent; a blank
/// cell in the file is stored as the long name.
pub const SubDef = struct {
    long: []const u8,
    path: []const u8,
    help: []const u8,
    field_name: []const u8,
};

fn validateSegment(comptime segment: []const u8) void {
    if (segment.len == 0) @compileError("empty subcommand path");
    if (segment.len > max_segment_len)
        @compileError("subcommand path is longer than 255 bytes: " ++ segment);
    if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, ".."))
        @compileError("subcommand path cannot be '.' or '..'");
    for (segment) |c| {
        if (c == '/' or c == '\\' or c == 0)
            @compileError("subcommand path must be one directory name: " ++ segment);
    }
}

fn parseSubLine(comptime line: []const u8) SubDef {
    var index: usize = 0;
    const long = readField(line, &index);
    const path_cell = readField(line, &index);
    const help = helpText(line, index);

    if (long.len == 0) @compileError("subcommand needs a long name: " ++ line);
    if (long[0] == '-') @compileError("subcommand name cannot start with '-': " ++ long);
    const segment = if (path_cell.len == 0) long else path_cell;
    validateSegment(segment);

    return .{
        .long = long,
        .path = segment,
        .help = help,
        .field_name = fieldNameFrom(long),
    };
}

fn rejectDuplicateSub(comptime prev: []const SubDef, comptime sub: SubDef) void {
    for (prev) |old| {
        if (std.mem.eql(u8, old.field_name, sub.field_name))
            @compileError("duplicate subcommand name: " ++ sub.field_name);
        if (std.mem.eql(u8, old.long, sub.long))
            @compileError("duplicate subcommand: " ++ sub.long);
        if (std.mem.eql(u8, old.path, sub.path))
            @compileError("duplicate subcommand path: " ++ sub.path);
    }
}

/// Parse a `sub.csv`. Columns: `long,path,help`.
/// The first row is skipped when it starts with `long,path,`.
pub fn parseSubCsv(comptime csv: []const u8) []const SubDef {
    const result = comptime blk: {
        @setEvalBranchQuota(200_000);
        var lines = std.mem.splitScalar(u8, csv, '\n');
        var defs: [max_defs]SubDef = undefined;
        var count: usize = 0;
        var saw_header = false;

        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (!saw_header and std.mem.startsWith(u8, line, "long,path,")) {
                saw_header = true;
                continue;
            }
            if (count == defs.len) @compileError("too many subcommands");
            const sub = parseSubLine(line);
            rejectDuplicateSub(defs[0..count], sub);
            defs[count] = sub;
            count += 1;
        }

        const stored = defs[0..count].*;
        break :blk &stored;
    };
    return result;
}

fn childDir(comptime parent: []const u8, comptime sub: SubDef) []const u8 {
    const full = parent ++ sub.path ++ "/";
    if (full.len + "args.csv".len > max_schema_path)
        @compileError("schema path exceeds 4096 bytes; set a shorter path mask for " ++ sub.long);
    return full;
}

fn levelDefs(comptime embed: anytype, comptime dir: []const u8) []const ArgDef {
    return parseCsv(embed(dir ++ "args.csv"));
}

fn levelSubs(comptime embed: anytype, comptime dir: []const u8) []const SubDef {
    return parseSubCsv(embed(dir ++ "sub.csv"));
}

/// Prose for this command's help page. `desc.txt` is optional; a missing or
/// blank file prints nothing. Leading and trailing whitespace is ignored.
fn levelDesc(comptime embed: anytype, comptime dir: []const u8) []const u8 {
    const text = comptime std.mem.trim(u8, embed(dir ++ "desc.txt"), " \t\r\n");
    return text;
}

/// Command words from `args/` to `dir`, joined by spaces. The path mask is
/// not included: `args/a/r/` for the `add` / `recursive` commands is
/// `add recursive`.
fn commandPath(comptime embed: anytype, comptime dir: []const u8) []const u8 {
    const found = comptime commandPathFrom(embed, command_root, dir);
    return found;
}

fn commandPathFrom(
    comptime embed: anytype,
    comptime here: []const u8,
    comptime target: []const u8,
) []const u8 {
    const found = comptime blk: {
        if (std.mem.eql(u8, here, target)) break :blk "";
        const subs = levelSubs(embed, here);
        var matched: ?[]const u8 = null;
        for (subs) |sub| {
            const child = childDir(here, sub);
            if (std.mem.eql(u8, child, target) or std.mem.startsWith(u8, target, child)) {
                const rest = commandPathFrom(embed, child, target);
                matched = if (rest.len == 0) sub.long else sub.long ++ " " ++ rest;
                break;
            }
        }
        if (matched) |words| break :blk words;
        @compileError("help directory is not in the command tree: " ++ target);
    };
    return found;
}

fn commandSuffix(comptime subs: []const SubDef) []const u8 {
    if (subs.len == 0) return "";
    return "[command]";
}

fn levelUsage(comptime defs: []const ArgDef, comptime subs: []const SubDef) []const u8 {
    const joined = comptime blk: {
        const base = usageSuffix(defs);
        const extra = commandSuffix(subs);
        if (extra.len == 0) break :blk base;
        if (base.len == 0) break :blk extra;
        break :blk base ++ " " ++ extra;
    };
    return joined;
}

fn makeCommandUnion(
    comptime embed: anytype,
    comptime dir: []const u8,
    comptime subs: []const SubDef,
    comptime depth: usize,
) type {
    const n = subs.len;
    var names: [n][]const u8 = undefined;
    var types: [n]type = undefined;
    inline for (subs, 0..) |sub, i| {
        names[i] = sub.field_name;
        types[i] = commandTypeDepth(embed, childDir(dir, sub), depth + 1);
    }
    const Tag = @Enum(u32, .exhaustive, &names, &std.simd.iota(u32, n));
    const attrs: [n]std.lang.Type.Union.FieldAttributes = @splat(.{});
    return @Union(.auto, Tag, &names, &types, &attrs);
}

fn makeLevelStruct(comptime defs: []const ArgDef, comptime Command: type) type {
    for (defs) |def| {
        if (std.mem.eql(u8, def.field_name, "command"))
            @compileError("option name 'command' is reserved when a level has subcommands");
    }
    const n = defs.len + 1;
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
    field_names[defs.len] = "command";
    field_types[defs.len] = ?Command;
    field_attrs[defs.len] = .{
        .default_value_ptr = defaultPtr(@as(?Command, null)),
        .@"align" = @alignOf(?Command),
    };
    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

fn commandTypeDepth(comptime embed: anytype, comptime dir: []const u8, comptime depth: usize) type {
    @setEvalBranchQuota(10_000_000);
    if (depth > max_command_depth) {
        @compileError(std.fmt.comptimePrint(
            "subcommand nesting is deeper than {d} at {s}",
            .{ max_command_depth, dir },
        ));
    }
    const defs = levelDefs(embed, dir);
    const subs = levelSubs(embed, dir);
    if (subs.len == 0) return makeResultType(defs);
    const Command = makeCommandUnion(embed, dir, subs, depth);
    return makeLevelStruct(defs, Command);
}

/// Result type for the schema `embed` loads.
///
/// The module exported by this package calls this with the directory given by
/// the `args` build option. `embed` is asked for `args/args.csv`,
/// `args/sub.csv`, and one pair of files per command directory. A command
/// row's `path` cell is the child directory; a blank cell uses the long name.
/// `add` with path `a`, then `recursive` with path `r`, loads
/// `args/a/r/args.csv` and `args/a/r/sub.csv`. An empty `args.csv`, including
/// one supplied when the file is absent, is a command with no options. An
/// empty `sub.csv` is a leaf with no `command` field. A level with commands
/// has `command: ?Union`. Null means the word was omitted, so this level is
/// the parent process.
pub fn commandType(comptime embed: anytype) type {
    return commandTypeDepth(embed, command_root, 1);
}

fn parseLevel(
    comptime embed: anytype,
    comptime dir: []const u8,
    comptime depth: usize,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    start: usize,
    level_dir: *[]const u8,
) (Error || std.mem.Allocator.Error)!commandTypeDepth(embed, dir, depth) {
    level_dir.* = dir;
    const defs = comptime levelDefs(embed, dir);
    const subs = comptime levelSubs(embed, dir);
    const Result = commandTypeDepth(embed, dir, depth);

    var result: Result = .{};
    var buckets: BucketArray(defs.len) = undefined;
    for (&buckets) |*bucket| bucket.* = .empty;
    defer for (&buckets) |*bucket| bucket.deinit(allocator);
    var seen: [defs.len]bool = @splat(false);

    const scan = try scanOptions(defs, subs, allocator, &result, &buckets, &seen, argv, start);

    // A named command is parsed before this level's required options, so
    // `cmd sub -h` can show the child page without the parent values.
    if (scan.sub) |chosen| {
        inline for (subs, 0..) |sub, k| {
            if (chosen == k) {
                const child_dir = comptime childDir(dir, sub);
                const child = try parseLevel(
                    embed,
                    child_dir,
                    depth + 1,
                    allocator,
                    argv,
                    scan.next,
                    level_dir,
                );
                errdefer deinitLevel(embed, child_dir, depth + 1, allocator, child);
                try finishMultis(defs, allocator, &result, &buckets, &seen);
                errdefer deinitArgs(defs, allocator, result);
                const Command = @typeInfo(@TypeOf(result.command)).optional.child;
                result.command = @unionInit(Command, sub.field_name, child);
            }
        }
        return result;
    }

    try finishMultis(defs, allocator, &result, &buckets, &seen);
    errdefer deinitArgs(defs, allocator, result);
    if (comptime subs.len == 0) return result;
    result.command = null;
    return result;
}

/// Parse `argv` against the `args/` tree next to `embed`.
///
/// Options before the command word belong to that folder's `args.csv`. The
/// word selects a row of `sub.csv`, and the rest of `argv` belongs to the
/// child. Omitting the word leaves `command` null, which is the parent
/// process. `-h` and `--help` are `error.Help` for the level being parsed.
///
/// Any error other than `error.OutOfMemory` prints that level's help and
/// exits the process (`0` for help, `1` otherwise). Tests receive the error
/// instead, so they can assert it.
pub fn parse(
    comptime embed: anytype,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) (Error || std.mem.Allocator.Error)!commandType(embed) {
    var level: []const u8 = command_root;
    return parseLevel(embed, command_root, 1, allocator, argv, 1, &level) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (!builtin.is_test) {
            const program = if (argv.len == 0) "" else argv[0];
            printCommandHelp(embed, program, level);
            std.process.exit(if (err == error.Help) 0 else 1);
        }
        return err;
    };
}

fn openCommands(
    comptime embed: anytype,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    level_dir: *[]const u8,
) (Error || std.mem.Allocator.Error)!commandType(embed) {
    return parseLevel(embed, command_root, 1, allocator, argv, 1, level_dir);
}

fn deinitLevel(
    comptime embed: anytype,
    comptime dir: []const u8,
    comptime depth: usize,
    allocator: std.mem.Allocator,
    result: anytype,
) void {
    const defs = comptime levelDefs(embed, dir);
    deinitArgs(defs, allocator, result);
    const subs = comptime levelSubs(embed, dir);
    if (comptime subs.len == 0) return;
    const command = result.command orelse return;
    switch (command) {
        inline else => |child, tag| {
            inline for (subs) |sub| {
                if (comptime std.mem.eql(u8, sub.field_name, @tagName(tag))) {
                    deinitLevel(embed, childDir(dir, sub), depth + 1, allocator, child);
                }
            }
        },
    }
}

/// Free slices owned by a result from `parse`, including the selected command
/// at every level. Do not pass a bare `commandType{}`.
pub fn deinit(comptime embed: anytype, allocator: std.mem.Allocator, result: anytype) void {
    deinitLevel(embed, command_root, 1, allocator, result);
}

fn printCommandList(comptime subs: []const SubDef) void {
    if (subs.len == 0) return;
    const width = comptime blk: {
        var width: usize = "command".len;
        for (subs) |sub| width = @max(width, sub.long.len);
        break :blk width;
    };
    const row = comptime std.fmt.comptimePrint("  {{s: <{d}}}   {{s}}\n", .{width});
    std.debug.print("\nCommands\n\n", .{});
    std.debug.print(row, .{ "command", "description" });
    inline for (subs) |sub| {
        std.debug.print(row, .{ sub.long, sub.help });
    }
}

fn printChildUsageLines(
    comptime embed: anytype,
    comptime dir: []const u8,
    name: []const u8,
    comptime words: []const u8,
) void {
    const subs = comptime levelSubs(embed, dir);
    inline for (subs) |sub| {
        const child_dir = comptime childDir(dir, sub);
        const child_words = if (comptime words.len == 0) sub.long else words ++ " " ++ sub.long;
        const child_suffix = comptime levelUsage(
            levelDefs(embed, child_dir),
            levelSubs(embed, child_dir),
        );
        printUsageLine(name, child_words, child_suffix);
    }
}

fn printMatchingHelp(
    comptime embed: anytype,
    comptime dir: []const u8,
    program: []const u8,
    level_dir: []const u8,
) bool {
    const subs = comptime levelSubs(embed, dir);
    if (std.mem.eql(u8, level_dir, dir)) {
        const defs = comptime levelDefs(embed, dir);
        const words = comptime commandPath(embed, dir);
        const name = programName(program);
        std.debug.print("Usage\n", .{});
        printUsageLine(name, words, comptime levelUsage(defs, subs));
        printChildUsageLines(embed, dir, name, words);
        const desc = comptime levelDesc(embed, dir);
        if (comptime desc.len == 0) {
            std.debug.print("\n", .{});
        } else {
            std.debug.print("\n{s}\n\n", .{desc});
        }
        writeOptionTable(defs);
        printCommandList(subs);
        return true;
    }
    inline for (subs) |sub| {
        if (printMatchingHelp(embed, childDir(dir, sub), program, level_dir))
            return true;
    }
    return false;
}

/// Print help for one level of the `args/` tree.
/// `level_dir` is a folder such as `args/remote/sync/`. An unrecognized
/// directory prints the root.
pub fn printCommandHelp(
    comptime embed: anytype,
    program: []const u8,
    level_dir: []const u8,
) void {
    if (!printMatchingHelp(embed, command_root, program, level_dir)) {
        _ = printMatchingHelp(embed, command_root, program, command_root);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const example_defs = parseCsv(@embedFile("args/args.csv"));

const showcase_defs = parseCsv(
    \\short,long,type,arity,default,help
    \\v,verbose,bool,0,false,Enable verbose output
    \\b,backup,bool,0,false,Create a backup
    \\p,port,u16,1,8080,Listen port
    \\o,output,?[]const u8,*,null,Output files
    \\f,file,[]const u8,+,,One or more input files
);

test "an empty csv is a command with no options and no children" {
    try std.testing.expectEqual(@as(usize, 0), parseCsv("").len);
    try std.testing.expectEqual(@as(usize, 0), parseSubCsv("").len);
    try std.testing.expectEqual(@as(usize, 0), parseSubCsv("long,path,help\n").len);
}

test "embedded args.csv is the argument template" {
    try std.testing.expectEqual(@as(usize, 1), example_defs.len);
    try std.testing.expectEqualStrings("verbose", example_defs[0].field_name);
    try std.testing.expectEqual(Arity.flag, example_defs[0].arity);
    const subs = parseSubCsv(@embedFile("args/sub.csv"));
    try std.testing.expectEqual(@as(usize, 3), subs.len);
    try std.testing.expectEqualStrings("add", subs[0].long);
    try std.testing.expectEqualStrings("serve", subs[1].long);
    try std.testing.expectEqualStrings("remote", subs[2].long);
    try std.testing.expectEqualStrings("remote", subs[2].path);
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
    const defs = showcase_defs;
    const Result = makeResultType(defs);
    const args: Result = .{};
    try std.testing.expectEqual(false, args.verbose);
    try std.testing.expectEqual(false, args.backup);
    try std.testing.expectEqual(@as(u16, 8080), args.port);
    try std.testing.expect(args.output == null);
    try std.testing.expectEqual(@as(usize, 0), args.file.len);
}

test "parse flags, strings, integers, and repeated options" {
    const defs = showcase_defs;
    const Result = makeResultType(defs);
    const allocator = std.testing.allocator;
    const args = try parseArgs(defs, Result, allocator, &.{
        "prog",
        "-vb",
        "--port=9000",
        "--output",
        "out.txt",
        "also.txt",
        "-f",
        "a.txt",
        "b.txt",
    });
    defer deinitArgs(defs, allocator, args);

    try std.testing.expectEqual(true, args.verbose);
    try std.testing.expectEqual(true, args.backup);
    try std.testing.expectEqual(@as(u16, 9000), args.port);
    try std.testing.expectEqual(@as(usize, 2), args.output.?.len);
    try std.testing.expectEqualStrings("out.txt", args.output.?[0]);
    try std.testing.expectEqualStrings("also.txt", args.output.?[1]);
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
    const args = try parseArgs(defs, Result, allocator, &.{
        "prog",
        "-nzig",
        "--count",
        "4",
        "--dry-run",
        "--tag",
        "1",
        "2",
    });
    defer deinitArgs(defs, allocator, args);

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
    const args = try parseArgs(defs, Result, allocator, &.{"prog"});
    defer deinitArgs(defs, allocator, args);
    try std.testing.expectEqualStrings("world", args.name);
    try std.testing.expectEqual(@as(usize, 0), args.tag.len);
}

test "multi options stop at the next option" {
    const defs = showcase_defs;
    const Result = makeResultType(defs);
    const allocator = std.testing.allocator;
    const args = try parseArgs(defs, Result, allocator, &.{
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
    defer deinitArgs(defs, allocator, args);

    try std.testing.expectEqual(@as(u16, 7), args.port);
    try std.testing.expectEqualStrings("out.txt", args.output.?[0]);
    try std.testing.expectEqual(@as(usize, 3), args.file.len);
    try std.testing.expectEqualStrings("a.txt", args.file[0]);
    try std.testing.expectEqualStrings("b.txt", args.file[1]);
    try std.testing.expectEqualStrings("c.txt", args.file[2]);

    const dashed = try parseArgs(defs, Result, allocator, &.{
        "prog",
        "--file",
        "plain.txt",
        "--",
        "-odd.txt",
    });
    defer deinitArgs(defs, allocator, dashed);
    try std.testing.expect(dashed.output == null);
    try std.testing.expectEqual(@as(usize, 2), dashed.file.len);
    try std.testing.expectEqualStrings("plain.txt", dashed.file[0]);
    try std.testing.expectEqualStrings("-odd.txt", dashed.file[1]);

    const attached = try parseArgs(defs, Result, allocator, &.{
        "prog",
        "--file=a.txt",
        "b.txt",
    });
    defer deinitArgs(defs, allocator, attached);
    try std.testing.expectEqualStrings("a.txt", attached.file[0]);
    try std.testing.expectEqualStrings("b.txt", attached.file[1]);
}

test "errors for unknown, missing, invalid, positional, and help" {
    const defs = showcase_defs;
    const Result = makeResultType(defs);
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnknownOption, parseArgs(defs, Result, allocator, &.{ "prog", "--nope" }));
    try std.testing.expectError(error.MissingValue, parseArgs(defs, Result, allocator, &.{ "prog", "--port" }));
    try std.testing.expectError(error.InvalidValue, parseArgs(defs, Result, allocator, &.{ "prog", "--port", "nope" }));
    try std.testing.expectError(error.UnexpectedPositional, parseArgs(defs, Result, allocator, &.{ "prog", "extra" }));
    try std.testing.expectError(error.MissingArgument, parseArgs(defs, Result, allocator, &.{"prog"}));
    try std.testing.expectError(error.Help, parseArgs(defs, Result, allocator, &.{ "prog", "--help" }));
    try std.testing.expectError(error.Help, parseArgs(defs, Result, allocator, &.{ "prog", "-h" }));
    try std.testing.expectError(error.UnexpectedValue, parseArgs(defs, Result, allocator, &.{ "prog", "--verbose=true" }));
}

test "help labels show defaults and mark required options" {
    try std.testing.expectEqualStrings("-v, --verbose", optionLabel(showcase_defs[0]));
    try std.testing.expectEqualStrings("false", defaultLabel(showcase_defs[0]));
    try std.testing.expectEqualStrings("-b, --backup", optionLabel(showcase_defs[1]));
    try std.testing.expectEqualStrings("false", defaultLabel(showcase_defs[1]));
    try std.testing.expectEqualStrings("-p, --port <u16>", optionLabel(showcase_defs[2]));
    try std.testing.expectEqualStrings("8080", defaultLabel(showcase_defs[2]));
    try std.testing.expectEqualStrings("-o, --output <text...>", optionLabel(showcase_defs[3]));
    try std.testing.expectEqualStrings("none", defaultLabel(showcase_defs[3]));
    try std.testing.expectEqualStrings("-f, --file <text...>", optionLabel(showcase_defs[4]));
    try std.testing.expectEqualStrings("required", defaultLabel(showcase_defs[4]));
    try std.testing.expectEqualStrings("-f <text...> [options]", usageSuffix(showcase_defs));
    try std.testing.expectEqual(@as(usize, 22), helpWidths(showcase_defs).option);
    try std.testing.expectEqual(@as(usize, 8), helpWidths(showcase_defs).default);

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
    try std.testing.expect(isRequired(defs[4]));
    try std.testing.expectEqualStrings("required", defaultLabel(defs[4]));
    try std.testing.expectEqualStrings("out.txt", defaultLabel(defs[5]));
    try std.testing.expectEqualStrings("-p, --port <u16>", optionLabel(defs[6]));
    try std.testing.expectEqualStrings("none", defaultLabel(defs[6]));
    try std.testing.expectEqualStrings("true", defaultLabel(defs[7]));
    try std.testing.expectEqualStrings("-e <text> -f <text...> --also <text...> [options]", usageSuffix(defs));

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
    try std.testing.expectError(error.MissingArgument, parseArgs(defs, Result, allocator, &.{"prog"}));

    const args = try parseArgs(defs, Result, allocator, &.{ "prog", "--port", "9" });
    defer deinitArgs(defs, allocator, args);
    try std.testing.expectEqual(@as(u16, 9), args.port);
    try std.testing.expect(args.output == null);
    try std.testing.expect(args.name == null);
    try std.testing.expectEqual(@as(i32, 3), args.count);
    try std.testing.expectEqual(@as(usize, 2), args.file.len);
    try std.testing.expectEqualStrings("a.txt", args.file[0]);
    try std.testing.expectEqualStrings("b.txt", args.file[1]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, args.tag);
    try std.testing.expectEqualStrings("one", args.extra[0]);

    const replaced = try parseArgs(defs, Result, allocator, &.{
        "prog",
        "-p",
        "4",
        "-f",
        "c.txt",
        "d.txt",
    });
    defer deinitArgs(defs, allocator, replaced);
    try std.testing.expectEqual(@as(u16, 4), replaced.port);
    try std.testing.expectEqual(@as(usize, 2), replaced.file.len);
    try std.testing.expectEqualStrings("c.txt", replaced.file[0]);
    try std.testing.expectEqualStrings("d.txt", replaced.file[1]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, replaced.tag);
}

test "optional text is one value at arity 1 and a list at *" {
    const allocator = std.testing.allocator;

    const one = comptime parseCsv("o,output,?[]const u8,1,null,Output\n");
    const One = makeResultType(one);
    const single_missing = try parseArgs(one, One, allocator, &.{"prog"});
    defer deinitArgs(one, allocator, single_missing);
    try std.testing.expect(single_missing.output == null);
    const single = try parseArgs(one, One, allocator, &.{ "prog", "--output", "out.txt" });
    defer deinitArgs(one, allocator, single);
    try std.testing.expectEqualStrings("out.txt", single.output.?);
    try std.testing.expectEqualStrings("-o, --output <text>", optionLabel(one[0]));

    const many = comptime parseCsv("o,output,?[]const u8,*,,Outputs\n");
    const Many = makeResultType(many);
    const list_missing = try parseArgs(many, Many, allocator, &.{"prog"});
    defer deinitArgs(many, allocator, list_missing);
    try std.testing.expect(list_missing.output == null);
    const listed = try parseArgs(many, Many, allocator, &.{ "prog", "-o", "a.txt", "b.txt" });
    defer deinitArgs(many, allocator, listed);
    try std.testing.expectEqual(@as(usize, 2), listed.output.?.len);
    try std.testing.expectEqualStrings("a.txt", listed.output.?[0]);
    try std.testing.expectEqualStrings("b.txt", listed.output.?[1]);
    try std.testing.expectEqualStrings("-o, --output <text...>", optionLabel(many[0]));
    try std.testing.expectEqualStrings("none", defaultLabel(many[0]));
}

test "a schema-defined -h is a normal flag" {
    const defs = comptime parseCsv("h,hello,bool,0,false,Say hello\n");
    const Result = makeResultType(defs);
    const allocator = std.testing.allocator;
    const args = try parseArgs(defs, Result, allocator, &.{ "prog", "-h" });
    defer deinitArgs(defs, allocator, args);
    try std.testing.expectEqual(true, args.hello);
}

fn exampleEmbed(comptime path: []const u8) []const u8 {
    return @embedFile(path);
}

test "demo command tree parses three levels" {
    const allocator = std.testing.allocator;
    var level: []const u8 = "";

    try std.testing.expectError(
        error.MissingArgument,
        openCommands(exampleEmbed, allocator, &.{ "prog", "add", "-f", "a.txt" }, &level),
    );

    const added = try openCommands(exampleEmbed, allocator, &.{ "prog", "add", "-bf", "a.txt", "-v", "1", "-p", "3" }, &level);
    defer deinit(exampleEmbed, allocator, added);
    switch (added.command orelse return error.TestUnexpectedResult) {
        .add => |add| {
            try std.testing.expectEqual(true, add.backup);
            try std.testing.expectEqualStrings("1", add.version);
            try std.testing.expectEqual(@as(u8, 3), add.patch);
            try std.testing.expectEqualStrings("a.txt", add.file[0]);
        },
        else => return error.TestUnexpectedResult,
    }

    const served = try openCommands(exampleEmbed, allocator, &.{ "prog", "serve", "-p", "9" }, &level);
    defer deinit(exampleEmbed, allocator, served);
    switch (served.command orelse return error.TestUnexpectedResult) {
        .serve => |serve| try std.testing.expectEqual(@as(u16, 9), serve.port),
        else => return error.TestUnexpectedResult,
    }

    const parent = try openCommands(exampleEmbed, allocator, &.{"prog"}, &level);
    defer deinit(exampleEmbed, allocator, parent);
    try std.testing.expect(parent.command == null);
    try std.testing.expectEqual(false, parent.verbose);

    const remote_only = try openCommands(exampleEmbed, allocator, &.{ "prog", "remote" }, &level);
    defer deinit(exampleEmbed, allocator, remote_only);
    switch (remote_only.command orelse return error.TestUnexpectedResult) {
        .remote => |remote| {
            try std.testing.expect(remote.command == null);
            try std.testing.expectEqualStrings("origin", remote.name);
        },
        else => return error.TestUnexpectedResult,
    }

    const args = try openCommands(exampleEmbed, allocator, &.{
        "prog", "-v", "remote", "--name", "upstream", "sync", "--force", "push", "-t", "-f", "a.txt", "b.txt",
    }, &level);
    defer deinit(exampleEmbed, allocator, args);
    try std.testing.expectEqual(true, args.verbose);
    switch (args.command orelse return error.TestUnexpectedResult) {
        .remote => |remote| {
            try std.testing.expectEqualStrings("upstream", remote.name);
            switch (remote.command orelse return error.TestUnexpectedResult) {
                .sync => |sync| {
                    try std.testing.expectEqual(true, sync.force);
                    switch (sync.command orelse return error.TestUnexpectedResult) {
                        .push => |push| {
                            try std.testing.expectEqual(true, push.tags);
                            try std.testing.expectEqual(@as(usize, 2), push.file.len);
                            try std.testing.expectEqualStrings("a.txt", push.file[0]);
                            try std.testing.expectEqualStrings("b.txt", push.file[1]);
                        },
                        else => return error.TestUnexpectedResult,
                    }
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("args/remote/sync/push/", level);

    const pulled = try openCommands(exampleEmbed, allocator, &.{ "prog", "remote", "sync", "pull" }, &level);
    defer deinit(exampleEmbed, allocator, pulled);
    switch (pulled.command orelse return error.TestUnexpectedResult) {
        .remote => |remote| switch (remote.command orelse return error.TestUnexpectedResult) {
            .sync => |sync| switch (sync.command orelse return error.TestUnexpectedResult) {
                .pull => |pull| try std.testing.expectEqualStrings("main", pull.branch),
                else => return error.TestUnexpectedResult,
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "sub.csv path mask defaults to the long name" {
    const subs = comptime parseSubCsv(
        \\long,path,help
        \\add,a,Add a file
        \\build,,"Compile, please"
    );
    try std.testing.expectEqual(@as(usize, 2), subs.len);
    try std.testing.expectEqualStrings("add", subs[0].long);
    try std.testing.expectEqualStrings("a", subs[0].path);
    try std.testing.expectEqualStrings("build", subs[1].long);
    try std.testing.expectEqualStrings("build", subs[1].path);
    try std.testing.expectEqualStrings("Compile, please", subs[1].help);
}

fn treeEmbed(comptime path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, "desc.txt")) {
        if (std.mem.eql(u8, path, "args/desc.txt")) return "Add files, then serve or sync them.\n";
        return "";
    }
    if (std.mem.eql(u8, path, "args/args.csv"))
        return "v,verbose,bool,0,false,Verbose\nf,file,[]const u8,+,,Files\n";
    if (std.mem.eql(u8, path, "args/sub.csv"))
        return "long,path,help\nadd,a,Add a file\n";
    if (std.mem.eql(u8, path, "args/a/args.csv"))
        return "n,name,[]const u8,1,item,Name\n";
    if (std.mem.eql(u8, path, "args/a/sub.csv"))
        return "long,path,help\nrecursive,r,Go deeper\n";
    if (std.mem.eql(u8, path, "args/a/r/args.csv"))
        return "t,times,u8,1,1,Times\n";
    if (std.mem.eql(u8, path, "args/a/r/sub.csv"))
        return "long,path,help\n";
    @compileError("no schema file: " ++ path);
}

test "help for a masked command names that level" {
    printCommandHelp(treeEmbed, "tool", "args/");
    printCommandHelp(treeEmbed, "tool", "args/a/r/");
    printCommandHelp(blankPathEmbed, "tool", "args/");
}

test "desc.txt is the command's help prose" {
    try std.testing.expectEqualStrings("Add files, then serve or sync them.", levelDesc(treeEmbed, "args/"));
    try std.testing.expectEqualStrings("", levelDesc(treeEmbed, "args/a/"));
    try std.testing.expect(std.mem.indexOf(u8, levelDesc(exampleEmbed, "args/"), "project files") != null);
    try std.testing.expect(std.mem.indexOf(u8, levelDesc(exampleEmbed, "args/remote/sync/"), "\n") != null);
}

test "usage lines name the command path" {
    try std.testing.expectEqualStrings("", commandPath(exampleEmbed, "args/"));
    try std.testing.expectEqualStrings("remote sync", commandPath(exampleEmbed, "args/remote/sync/"));
    try std.testing.expectEqualStrings("remote sync push", commandPath(exampleEmbed, "args/remote/sync/push/"));
    try std.testing.expectEqualStrings("[options] [command]", levelUsage(
        levelDefs(exampleEmbed, "args/"),
        levelSubs(exampleEmbed, "args/"),
    ));
    try std.testing.expectEqualStrings("-f <text...> -v <text> -p <u8> [options]", levelUsage(
        levelDefs(exampleEmbed, "args/add/"),
        levelSubs(exampleEmbed, "args/add/"),
    ));
    try std.testing.expectEqualStrings("[options]", levelUsage(
        levelDefs(exampleEmbed, "args/serve/"),
        levelSubs(exampleEmbed, "args/serve/"),
    ));
    try std.testing.expectEqualStrings("[options] [command]", levelUsage(
        levelDefs(exampleEmbed, "args/remote/"),
        levelSubs(exampleEmbed, "args/remote/"),
    ));
    try std.testing.expectEqualStrings("[options] [command]", levelUsage(
        levelDefs(exampleEmbed, "args/remote/sync/"),
        levelSubs(exampleEmbed, "args/remote/sync/"),
    ));
    try std.testing.expectEqualStrings("-f <text...> [options]", levelUsage(
        levelDefs(exampleEmbed, "args/remote/sync/push/"),
        levelSubs(exampleEmbed, "args/remote/sync/push/"),
    ));
    try std.testing.expectEqualStrings("[options]", levelUsage(
        levelDefs(exampleEmbed, "args/remote/sync/pull/"),
        levelSubs(exampleEmbed, "args/remote/sync/pull/"),
    ));

    try std.testing.expectEqualStrings("add", commandPath(treeEmbed, "args/a/"));
    try std.testing.expectEqualStrings("add recursive", commandPath(treeEmbed, "args/a/r/"));
    try std.testing.expectEqualStrings("-f <text...> [options] [command]", levelUsage(
        levelDefs(treeEmbed, "args/"),
        levelSubs(treeEmbed, "args/"),
    ));
    try std.testing.expectEqualStrings("[options] [command]", levelUsage(
        levelDefs(treeEmbed, "args/a/"),
        levelSubs(treeEmbed, "args/a/"),
    ));
    try std.testing.expectEqualStrings("build", commandPath(blankPathEmbed, "args/build/"));
    try std.testing.expectEqualStrings("[options] [command]", levelUsage(
        levelDefs(blankPathEmbed, "args/"),
        levelSubs(blankPathEmbed, "args/"),
    ));
}

test "masked directories parse three levels" {
    const allocator = std.testing.allocator;
    var level: []const u8 = "";
    const args = try openCommands(treeEmbed, allocator, &.{
        "prog", "-v", "-f",   "in.txt",    "extra.txt",
        "add",  "-n", "item", "recursive", "--times",
        "4",
    }, &level);
    defer deinit(treeEmbed, allocator, args);

    try std.testing.expectEqual(true, args.verbose);
    try std.testing.expectEqual(@as(usize, 2), args.file.len);
    try std.testing.expectEqualStrings("in.txt", args.file[0]);
    try std.testing.expectEqualStrings("extra.txt", args.file[1]);
    switch (args.command orelse return error.TestUnexpectedResult) {
        .add => |add| {
            try std.testing.expectEqualStrings("item", add.name);
            switch (add.command orelse return error.TestUnexpectedResult) {
                .recursive => |recursive| {
                    try std.testing.expectEqual(@as(u8, 4), recursive.times);
                },
            }
        },
    }
    try std.testing.expectEqualStrings("args/a/r/", level);
}

test "a multi option stops before the subcommand" {
    const allocator = std.testing.allocator;
    var level: []const u8 = "";
    const swallowed = openCommands(treeEmbed, allocator, &.{
        "prog", "-f", "add",
    }, &level);
    try std.testing.expectError(error.MissingValue, swallowed);

    const args = try openCommands(treeEmbed, allocator, &.{
        "prog", "-f", "in.txt", "extra.txt", "add", "-n", "item", "recursive",
    }, &level);
    defer deinit(treeEmbed, allocator, args);
    try std.testing.expectEqual(@as(usize, 2), args.file.len);
    try std.testing.expectEqualStrings("in.txt", args.file[0]);
    try std.testing.expectEqualStrings("extra.txt", args.file[1]);
    switch (args.command orelse return error.TestUnexpectedResult) {
        .add => |add| try std.testing.expectEqualStrings("item", add.name),
    }
}

test "an omitted command is null" {
    const allocator = std.testing.allocator;
    var level: []const u8 = "";

    try std.testing.expectError(error.MissingArgument, openCommands(treeEmbed, allocator, &.{"prog"}, &level));
    try std.testing.expectEqualStrings("args/", level);

    const parent = try openCommands(treeEmbed, allocator, &.{ "prog", "-f", "in.txt" }, &level);
    defer deinit(treeEmbed, allocator, parent);
    try std.testing.expect(parent.command == null);
    try std.testing.expectEqualStrings("in.txt", parent.file[0]);
    try std.testing.expectEqualStrings("args/", level);

    const nested = try openCommands(treeEmbed, allocator, &.{ "prog", "-f", "in.txt", "add", "-n", "item" }, &level);
    defer deinit(treeEmbed, allocator, nested);
    switch (nested.command orelse return error.TestUnexpectedResult) {
        .add => |add| try std.testing.expect(add.command == null),
    }
    try std.testing.expectEqualStrings("args/a/", level);
}

test "unknown commands and help remember the level" {
    const allocator = std.testing.allocator;
    var level: []const u8 = "";
    try std.testing.expectError(error.UnknownCommand, openCommands(treeEmbed, allocator, &.{ "prog", "nope" }, &level));
    try std.testing.expectEqualStrings("args/", level);

    try std.testing.expectError(error.Help, openCommands(treeEmbed, allocator, &.{ "prog", "-h" }, &level));
    try std.testing.expectEqualStrings("args/", level);
    try std.testing.expectError(error.Help, openCommands(treeEmbed, allocator, &.{ "prog", "add", "-h" }, &level));
    try std.testing.expectEqualStrings("args/a/", level);
    try std.testing.expectError(error.Help, openCommands(treeEmbed, allocator, &.{ "prog", "add", "recursive", "--help" }, &level));
    try std.testing.expectEqualStrings("args/a/r/", level);

    try std.testing.expectError(error.UnknownCommand, parse(treeEmbed, allocator, &.{ "prog", "nope" }));
    try std.testing.expectError(error.Help, parse(treeEmbed, allocator, &.{ "prog", "add", "-h" }));
}

fn blankPathEmbed(comptime path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, "desc.txt")) return "";
    if (std.mem.eql(u8, path, "args/args.csv"))
        return "v,verbose,bool,0,false,Verbose\n";
    if (std.mem.eql(u8, path, "args/sub.csv"))
        return "long,path,help\nbuild,,Compile\n";
    if (std.mem.eql(u8, path, "args/build/args.csv"))
        return "n,name,[]const u8,1,app,Name\n";
    if (std.mem.eql(u8, path, "args/build/sub.csv"))
        return "long,path,help\n";
    @compileError("no schema file: " ++ path);
}

test "a blank path uses the long name" {
    const allocator = std.testing.allocator;
    var level: []const u8 = "";
    const omitted = try openCommands(blankPathEmbed, allocator, &.{"prog"}, &level);
    defer deinit(blankPathEmbed, allocator, omitted);
    try std.testing.expect(omitted.command == null);
    try std.testing.expectEqual(false, omitted.verbose);

    const chosen = try openCommands(blankPathEmbed, allocator, &.{ "prog", "build", "-n", "demo" }, &level);
    defer deinit(blankPathEmbed, allocator, chosen);
    switch (chosen.command orelse return error.TestUnexpectedResult) {
        .build => |build| try std.testing.expectEqualStrings("demo", build.name),
    }

    const via_parse = try parse(blankPathEmbed, allocator, &.{ "prog", "build" });
    defer deinit(blankPathEmbed, allocator, via_parse);
    switch (via_parse.command orelse return error.TestUnexpectedResult) {
        .build => |build| try std.testing.expectEqualStrings("app", build.name),
    }
}

const chain_depth = 32;

fn chainEmbed(comptime path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, "desc.txt")) return "";
    if (std.mem.endsWith(u8, path, "args.csv"))
        return "v,verbose,bool,0,false,Verbose\n";
    var slashes: usize = 0;
    for (path) |c| {
        if (c == '/') slashes += 1;
    }
    if (slashes <= chain_depth)
        return "long,path,help\nn,n,Down\n";
    return "long,path,help\n";
}

fn expectChain(value: anytype, left: usize) !void {
    if (comptime !@hasField(@TypeOf(value), "command")) {
        try std.testing.expectEqual(@as(usize, 0), left);
        try std.testing.expectEqual(true, value.verbose);
        return;
    }
    switch (value.command orelse return error.TestUnexpectedResult) {
        .n => |child| try expectChain(child, left - 1),
    }
}

test "command directories nest to the depth cap's neighborhood" {
    const allocator = std.testing.allocator;
    var argv: [chain_depth + 2][]const u8 = undefined;
    argv[0] = "prog";
    for (argv[1 .. chain_depth + 1]) |*slot| slot.* = "n";
    argv[chain_depth + 1] = "-v";

    var level: []const u8 = "";
    const args = try openCommands(chainEmbed, allocator, &argv, &level);
    defer deinit(chainEmbed, allocator, args);
    try expectChain(args, chain_depth);
    try std.testing.expect(std.mem.endsWith(u8, level, "/"));
    var slashes: usize = 0;
    for (level) |c| {
        if (c == '/') slashes += 1;
    }
    try std.testing.expectEqual(chain_depth + 1, slashes);
}
