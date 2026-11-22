const std = @import("std");
const zig_clap = @import("zig_clap");

// Schema files live next to this source file.
//
// args/                         -v
//   add/                        -f files, -o outputs, -b
//   serve/                      -p port, -o log
//   remote/                     --name
//     list/                     --only
//     sync/                     --force
//       push/                   -f files, -t
//       pull/                   --branch
fn embed(comptime path: []const u8) []const u8 {
    return @embedFile(path);
}

const command_root = "args/";
const Result = zig_clap.commandType(embed, command_root);

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(gpa);

    // Argument text points into this iterator. On Windows the iterator owns
    // that buffer, so it has to outlive `args`.
    var iterator = try init.minimal.args.iterateAllocator(gpa);
    defer iterator.deinit();
    while (iterator.next()) |arg| try argv_list.append(gpa, arg);

    var level: []const u8 = command_root;
    const args = zig_clap.parseCommands(embed, command_root, gpa, argv_list.items, &level) catch |err| {
        const program = if (argv_list.items.len == 0) "" else argv_list.items[0];
        zig_clap.printCommandHelp(embed, command_root, program, level);
        std.process.exit(if (err == error.Help) 0 else 1);
    };
    defer zig_clap.deinitCommands(embed, command_root, gpa, args);

    std.debug.print("verbose = {}\n", .{args.verbose});
    switch (args.command) {
        .add => |add| {
            std.debug.print("command = add\n", .{});
            std.debug.print("backup = {}\n", .{add.backup});
            if (add.output) |paths| {
                for (paths) |path| std.debug.print("output = {s}\n", .{path});
            }
            for (add.file) |path| std.debug.print("file = {s}\n", .{path});
        },
        .serve => |serve| {
            std.debug.print("command = serve\n", .{});
            std.debug.print("port = {d}\n", .{serve.port});
            if (serve.output) |path| std.debug.print("output = {s}\n", .{path});
        },
        .remote => |remote| {
            std.debug.print("command = remote\n", .{});
            std.debug.print("name = {s}\n", .{remote.name});
            switch (remote.command) {
                .list => |list| {
                    std.debug.print("remote = list\n", .{});
                    if (list.only) |name| std.debug.print("only = {s}\n", .{name});
                },
                .sync => |sync| {
                    std.debug.print("remote = sync\n", .{});
                    std.debug.print("force = {}\n", .{sync.force});
                    switch (sync.command) {
                        .push => |push| {
                            std.debug.print("sync = push\n", .{});
                            std.debug.print("tags = {}\n", .{push.tags});
                            for (push.file) |path| std.debug.print("file = {s}\n", .{path});
                        },
                        .pull => |pull| {
                            std.debug.print("sync = pull\n", .{});
                            std.debug.print("branch = {s}\n", .{pull.branch});
                        },
                    }
                },
            }
        },
    }
}
