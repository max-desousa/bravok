const std = @import("std");

pub const ArgDef = struct {
    short: ?u8 = null,
    long: []const u8,
    type_name: []const u8,
    arity: Arity,
    default_str: []const u8,
    help: []const u8,
    field_name: []const u8, // sanitized long name
};

pub const Arity = enum {
    flag,       // 0
    one,        // 1
    one_or_more, // +
    zero_or_more, // *
};

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

fn sanitizeName(comptime s: []const u8) []const u8 {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (s) |c| {
        buf[n] = if (c == '-') '_' else c;
        n += 1;
    }
    return buf[0..n];
}

pub fn parseCsv(comptime csv: []const u8) []const ArgDef {
    @setEvalBranchQuota(200_000);
    var lines = std.mem.splitScalar(u8, csv, '\n');
    _ = lines.next(); // header

    var defs: [32]ArgDef = undefined;
    var count: usize = 0;

    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;

        var f = std.mem.splitScalar(u8, line, ',');
        const short_s = f.next() orelse "";
        const long = f.next() orelse @compileError("missing long");
        const type_name = f.next() orelse @compileError("missing type");
        const arity_s = f.next() orelse "1";
        const default_str = f.next() orelse "";
        const help = f.next() orelse "";

        if (long.len == 0 and short_s.len == 0)
            @compileError("need at least one name");

        defs[count] = .{
            .short = if (short_s.len == 1) short_s[0] else null,
            .long = long,
            .type_name = type_name,
            .arity = parseArity(arity_s),
            .default_str = default_str,
            .help = help,
            .field_name = sanitizeName(long),
        };
        count += 1;
    }

    const result = defs[0..count].*;
    return &result;
}

// ---------------------------------------------------------------------------
// Type mapping
// ---------------------------------------------------------------------------

fn typeFromName(comptime name: []const u8) type {
    if (std.mem.eql(u8, name, "bool")) return bool;
    if (std.mem.eql(u8, name, "u8")) return u8;
    if (std.mem.eql(u8, name, "u16")) return u16;
    if (std.mem.eql(u8, name, "u32")) return u32;
    if (std.mem.eql(u8, name, "i32")) return i32;
    if (std.mem.eql(u8, name, "i64")) return i64;
    if (std.mem.eql(u8, name, "[]const u8")) return []const u8;
    if (std.mem.eql(u8, name, "?[]const u8")) return ?[]const u8;
    if (std.mem.eql(u8, name, "?bool")) return ?bool;
    if (std.mem.eql(u8, name, "?u32")) return ?u32;
    @compileError("unknown type: " ++ name);
}

fn isMulti(comptime def: ArgDef) bool {
    return def.arity == .one_or_more or def.arity == .zero_or_more;
}

fn resultFieldType(comptime def: ArgDef) type {
    const base = typeFromName(def.type_name);
    if (isMulti(def)) {
        return []const base; // slice of the base type
    }
    return base;
}

fn parseDefaultValue(comptime def: ArgDef) resultFieldType(def) {
    const T = resultFieldType(def);
    const s = def.default_str;

    if (isMulti(def)) {
        // multi defaults to empty slice
        return &.{};
    }

    if (std.mem.eql(u8, s, "null")) {
        if (@typeInfo(T) == .optional) return null;
        @compileError("null default only for optional types");
    }

    if (T == bool) return std.mem.eql(u8, s, "true");
    if (T == u16 or T == u32 or T == i32 or T == i64)
        return std.fmt.parseInt(T, s, 10) catch @compileError("bad int default");
    if (T == []const u8) return s;
    if (@typeInfo(T) == .optional) {
        // non-null default for optional – not implemented in this starter
        @compileError("non-null defaults for optionals not yet supported");
    }
    @compileError("default not implemented for type");
}

// ---------------------------------------------------------------------------
// Generate the Result struct
// ---------------------------------------------------------------------------

pub fn makeResultType(comptime defs: []const ArgDef) type {
    const n = defs.len;

    var field_names: [n][]const u8 = undefined;
    var field_types: [n]type = undefined;
    var field_attrs: [n]std.builtin.Type.Struct.FieldAttributes = @splat(.{});

    inline for (defs, 0..) |def, i| {
        const T = resultFieldType(def);
        const default_val: T = parseDefaultValue(def);

        field_names[i] = def.field_name;
        field_types[i] = T;
        field_attrs[i] = .{
            .default_value_ptr = &default_val,
            .@"align" = @alignOf(T),
        };
    }

    return @Struct(
        .auto,          // layout
        null,           // backing integer (only for packed)
        &field_names,
        &field_types,
        &field_attrs,
    );
}

// ---------------------------------------------------------------------------
// Runtime parser
// ---------------------------------------------------------------------------

pub fn parse(
    comptime defs: []const ArgDef,
    comptime Result: type,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) !Result {
    var result: Result = .{};

    // Temporary storage for multi-value options
    var multi_lists: [defs.len]std.ArrayList(u8) = undefined;
    for (&multi_lists) |*list| {
        list.* = std.ArrayList(u8).init(allocator);
    }
    defer for (&multi_lists) |*list| list.deinit();


    // We store the actual slices later; for now collect into ArrayLists of the base type.
    // Simpler approach: collect string slices for multi string options.
    // This starter assumes multi options are []const u8 based. Extend as needed.

    var i: usize = 1; // skip program name
    while (i < argv.len) {
        const arg = argv[i];

        if (std.mem.startsWith(u8, arg, "--")) {
            // long option
            const name = arg[2..];
            const eq = std.mem.indexOfScalar(u8, name, '=');
            const opt_name = if (eq) |e| name[0..e] else name;
            const inline_val = if (eq) |e| name[e + 1 ..] else null;

            const def_idx = findLong(defs, opt_name) orelse {
                std.debug.print("unknown option --{s}\n", .{opt_name});
                return error.UnknownOption;
            };
            const def = defs[def_idx];

            if (def.arity == .flag) {
                @field(result, def.field_name) = true;
                i += 1;
                continue;
            }

            const value = inline_val orelse blk: {
                i += 1;
                if (i >= argv.len) return error.MissingValue;
                break :blk argv[i];
            };

            try setValue(allocator, &result, def, value);
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            // short cluster or short with value
            const cluster = arg[1..];
            var c: usize = 0;
            while (c < cluster.len) : (c += 1) {
                const ch = cluster[c];
                const def_idx = findShort(defs, ch) orelse {
                    std.debug.print("unknown short -{c}\n", .{ch});
                    return error.UnknownOption;
                };
                const def = defs[def_idx];

                if (def.arity == .flag) {
                    @field(result, def.field_name) = true;
                    continue;
                }

                // value-taking short
                const value = if (c + 1 < cluster.len)
                    cluster[c + 1 ..]
                else blk: {
                    i += 1;
                    if (i >= argv.len) return error.MissingValue;
                    break :blk argv[i];
                };

                try setValue(allocator, &result, def, value);
                break; // rest of cluster is the value
            }
            i += 1;
        } else {
            // positional – ignored in this starter
            i += 1;
        }
    }

    // Finalize multi-value fields (placeholder – see note below)
    _ = multi_lists;

    return result;
}

fn findLong(comptime defs: []const ArgDef, name: []const u8) ?usize {
    inline for (defs, 0..) |def, i| {
        if (std.mem.eql(u8, def.long, name)) return i;
    }
    return null;
}

fn findShort(comptime defs: []const ArgDef, ch: u8) ?usize {
    inline for (defs, 0..) |def, i| {
        if (def.short) |s| {
            if (s == ch) return i;
        }
    }
    return null;
}

fn setValue(
    allocator: std.mem.Allocator,
    result: anytype,
    comptime def: ArgDef,
    value: []const u8,
) !void {
    const T = resultFieldType(def);
    if (isMulti(def)) {
        // Collect into a temporary list then assign slice.
        // Full multi-collection is left as the next step; this shows the hook.
        _ = allocator;
        _ = result;
        _ = value;
        // TODO: append to a list associated with this field
        return;
    }

    if (T == bool) {
        @field(result, def.field_name) = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
    } else if (T == u16 or T == u32 or T == i32 or T == i64) {
        @field(result, def.field_name) = try std.fmt.parseInt(T, value, 10);
    } else if (T == []const u8) {
        @field(result, def.field_name) = value;
    } else if (@typeInfo(T) == .optional) {
        // treat presence as non-null
        const Child = @typeInfo(T).optional.child;
        if (Child == []const u8) {
            @field(result, def.field_name) = value;
        } else if (Child == u32 or Child == u16) {
            @field(result, def.field_name) = try std.fmt.parseInt(Child, value, 10);
        }
    }
}

// ---------------------------------------------------------------------------
// Help
// ---------------------------------------------------------------------------

pub fn printHelp(comptime defs: []const ArgDef) void {
    std.debug.print("Options:\n", .{});
    inline for (defs) |def| {
        const short_str = if (def.short) |s| &[_]u8{ '-', s, ' ' } else "   ";
        std.debug.print("  {s}--{s:<12} {s}\n", .{ short_str, def.long, def.help });
    }
}

// ---------------------------------------------------------------------------
// Example usage (in main.zig)
// ---------------------------------------------------------------------------

// const csv = @embedFile("args.csv");
//const csv =
//    \\short,long,type,arity,default,help
//    \\v,verbose,bool,0,false,Enable verbose output
//    \\b,backup,bool,0,false,Create a backup
//    \\p,port,u16,1,8080,Listen port
//    \\o,output,?[]const u8,1,null,Optional output file
//    \\f,file,[]const u8,+, ,One or more input files
//;
//
//pub const defs = parseCsv(csv);
//pub const Result = makeResultType(defs);

// In main:
// pub fn main() !void {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     defer _ = gpa.deinit();
//     const allocator = gpa.allocator();
//
//     const argv = try std.process.argsAlloc(allocator);
//     defer std.process.argsFree(allocator, argv);
//
//     const args = try parse(defs, Result, allocator, argv);
//     std.debug.print("port = {d}\n", .{args.port});
//     std.debug.print("verbose = {}\n", .{args.verbose});
// }
