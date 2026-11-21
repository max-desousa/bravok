const std = @import("std");
const zig_clap = @import("zig_clap");

// `args.csv` is the comptime template for the argument types.
const defs = zig_clap.parseCsv(@embedFile("args.csv"));
const Result = zig_clap.makeResultType(defs);

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(gpa);

    // Argument text points into this iterator. On Windows the iterator owns
    // that buffer, so it has to outlive `args`.
    var iterator = try init.minimal.args.iterateAllocator(gpa);
    defer iterator.deinit();
    while (iterator.next()) |arg| try argv_list.append(gpa, arg);

    const args = zig_clap.parse(defs, Result, gpa, argv_list.items) catch |err| {
        const program = if (argv_list.items.len == 0) "" else argv_list.items[0];
        zig_clap.printHelp(defs, program);
        std.process.exit(if (err == error.Help) 0 else 1);
    };
    defer zig_clap.deinit(defs, gpa, args);

    std.debug.print("port = {d}\n", .{args.port});
    std.debug.print("verbose = {}\n", .{args.verbose});
    std.debug.print("backup = {}\n", .{args.backup});
    if (args.output) |path| std.debug.print("output = {s}\n", .{path});
    for (args.file) |path| std.debug.print("file = {s}\n", .{path});
}
