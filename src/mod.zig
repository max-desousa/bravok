const std = @import("std");
const engine = @import("engine");
const schema = @import("schema");

pub const ArgDef = engine.ArgDef;
pub const Arity = engine.Arity;
pub const Error = engine.Error;
pub const SubDef = engine.SubDef;
pub const max_command_depth = engine.max_command_depth;
pub const parseCsv = engine.parseCsv;
pub const parseSubCsv = engine.parseSubCsv;
pub const makeResultType = engine.makeResultType;
pub const printHelp = engine.printHelp;

/// Result type for the schema directory selected in `build.zig`.
pub fn commandType() type {
    return engine.commandType(schema.embed);
}

/// Parse `argv`. A usage error prints help and exits. `error.OutOfMemory`
/// is returned.
pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) !commandType() {
    return engine.parse(schema.embed, allocator, argv);
}

/// Free slices owned by a result from `parse`.
pub fn deinit(allocator: std.mem.Allocator, result: anytype) void {
    engine.deinit(schema.embed, allocator, result);
}

pub fn printCommandHelp(program: []const u8, level_dir: []const u8) void {
    engine.printCommandHelp(schema.embed, program, level_dir);
}
