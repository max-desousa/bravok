const std = @import("std");
const zig_clap = @import("zig_clap");

// The schema directory is the `args` option in build.zig. This demo uses
// src/args. The folder name is free; these names inside it are fixed.
//
// args.csv                      -v
// sub.csv                       add, serve, remote
// add/                          -f files, -o outputs, -b
// serve/                        -p port, -o log
// remote/                       --name
//   list/                       --only
//   sync/                       --force
//     push/                     -f files, -t
//     pull/                     --branch
const Result = zig_clap.commandType();

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(gpa);

    // Argument text points into this iterator. On Windows the iterator owns
    // that buffer, so it has to outlive `args`.
    var iterator = try init.minimal.args.iterateAllocator(gpa);
    defer iterator.deinit();
    while (iterator.next()) |arg| try argv_list.append(gpa, arg);

    // A usage error prints help and exits. `try` only surfaces out of memory.
    const args: Result = try zig_clap.parse(gpa, argv_list.items);
    defer zig_clap.deinit(gpa, args);

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
