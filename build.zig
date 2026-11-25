const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependents pass this. The root package defaults to the demo schema.
    //
    //   const dep = b.dependency("zig_clap", .{
    //       .target = target,
    //       .optimize = optimize,
    //       .args = b.path("src/cli"),
    //   });
    //   exe.root_module.addImport("zig_clap", dep.module("zig_clap"));
    //
    // `src/cli` may be any folder name. `args.csv` and `sub.csv` are optional
    // in each directory: omit `args.csv` for no options, omit `sub.csv` for
    // no children. `desc.txt` is optional prose on that command's help page.
    // A `sub.csv` row's `path` cell is the child directory, and a blank cell
    // uses the long name. The directory itself must exist.
    const args_dir = b.option(
        std.Build.LazyPath,
        "args",
        "Schema directory. The folder name is free; args.csv and sub.csv are fixed",
    ) orelse if (b.isRoot())
        b.path("src/args")
    else
        std.process.fatal("zig_clap needs .args = b.path(\"path/to/schema\")", .{});

    const mod = clapModule(b, target, optimize, args_dir);

    if (!b.isRoot()) return;

    const exe = b.addExecutable(.{
        .name = "zig_clap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_clap", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

fn clapModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    args_dir: std.Build.LazyPath,
) *std.Build.Module {
    const schema_file = b.addWriteFiles().add("schema.zig", schemaSource(b, args_dir));
    const schema = b.createModule(.{
        .root_source_file = schema_file,
        .target = target,
        .optimize = optimize,
    });
    const engine = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    return b.addModule("zig_clap", .{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "engine", .module = engine },
            .{ .name = "schema", .module = schema },
        },
    });
}

const Loaded = struct {
    key: []const u8,
    bytes: []const u8,
};

fn schemaSource(b: *std.Build, args_dir: std.Build.LazyPath) []const u8 {
    const arena = b.graph.arena;
    const io = b.graph.io;
    const root = schemaCachePath(b, args_dir);
    var dir = root.openDir(io, "", .{}) catch |err| {
        std.process.fatal("cannot open zig_clap schema directory {s}: {t}", .{ schemaLabel(args_dir), err });
    };
    defer dir.close(io);

    var files: std.ArrayList(Loaded) = .empty;
    defer files.deinit(b.allocator);
    loadLevel(b, args_dir, dir, "", &files, 1);

    var out: std.Io.Writer.Allocating = .init(b.allocator);
    defer out.deinit();
    out.writer.writeAll(
        \\const std = @import("std");
        \\
        \\pub fn embed(comptime path: []const u8) []const u8 {
        \\
    ) catch @panic("OOM");
    for (files.items) |file| {
        out.writer.print(
            "    if (std.mem.eql(u8, path, \"{f}\")) return \"{f}\";\n",
            .{ std.zig.fmtString(file.key), std.zig.fmtString(file.bytes) },
        ) catch @panic("OOM");
    }
    out.writer.writeAll(
        \\    @compileError("no schema file: " ++ path);
        \\}
        \\
    ) catch @panic("OOM");
    const text = out.toOwnedSlice() catch @panic("OOM");
    defer b.allocator.free(text);
    return arena.dupe(u8, text) catch @panic("OOM");
}

fn loadLevel(
    b: *std.Build,
    root_lp: std.Build.LazyPath,
    dir: std.Io.Dir,
    rel_dir: []const u8,
    files: *std.ArrayList(Loaded),
    depth: usize,
) void {
    if (depth > 64) {
        std.process.fatal("subcommand nesting is deeper than 64 at {s}", .{rel_dir});
    }
    if (rel_dir.len != 0) {
        var child_dir = dir.openDir(b.graph.io, rel_dir, .{}) catch |err| {
            std.process.fatal("zig_clap schema {s} is missing command directory {s} ({t})", .{
                schemaLabel(root_lp), rel_dir, err,
            });
        };
        child_dir.close(b.graph.io);
    }
    const level = if (rel_dir.len == 0) root_lp else root_lp.path(b, rel_dir);
    b.dependOnDirectoryContents(level);
    _ = readSchemaFile(b, root_lp, dir, rel_dir, "args.csv", files);
    const sub_bytes = readSchemaFile(b, root_lp, dir, rel_dir, "sub.csv", files);
    readOptionalFile(b, root_lp, dir, rel_dir, "desc.txt", files);
    const children = childSegments(b.graph.arena, sub_bytes);
    for (children) |segment| {
        const child = if (rel_dir.len == 0)
            segment
        else
            std.fmt.allocPrint(b.graph.arena, "{s}/{s}", .{ rel_dir, segment }) catch @panic("OOM");
        loadLevel(b, root_lp, dir, child, files, depth + 1);
    }
}

fn readSchemaFile(
    b: *std.Build,
    root_lp: std.Build.LazyPath,
    dir: std.Io.Dir,
    rel_dir: []const u8,
    name: []const u8,
    files: *std.ArrayList(Loaded),
) []const u8 {
    const disk = if (rel_dir.len == 0)
        name
    else
        std.fmt.allocPrint(b.graph.arena, "{s}/{s}", .{ rel_dir, name }) catch @panic("OOM");
    const key = std.fmt.allocPrint(b.graph.arena, "args/{s}", .{disk}) catch @panic("OOM");
    const bytes = dir.readFileAlloc(b.graph.io, disk, b.graph.arena, .limited(1024 * 1024)) catch |err| switch (err) {
        // A missing file is an empty schema: no options, or no children.
        error.FileNotFound => {
            files.append(b.allocator, .{ .key = key, .bytes = "" }) catch @panic("OOM");
            return "";
        },
        else => std.process.fatal("zig_clap schema {s} could not read {s} ({t})", .{ schemaLabel(root_lp), disk, err }),
    };
    b.dependOnFileContents(root_lp.path(b, disk));
    files.append(b.allocator, .{ .key = key, .bytes = bytes }) catch @panic("OOM");
    return bytes;
}

fn readOptionalFile(
    b: *std.Build,
    root_lp: std.Build.LazyPath,
    dir: std.Io.Dir,
    rel_dir: []const u8,
    name: []const u8,
    files: *std.ArrayList(Loaded),
) void {
    const disk = if (rel_dir.len == 0)
        name
    else
        std.fmt.allocPrint(b.graph.arena, "{s}/{s}", .{ rel_dir, name }) catch @panic("OOM");
    const key = std.fmt.allocPrint(b.graph.arena, "args/{s}", .{disk}) catch @panic("OOM");
    const bytes = dir.readFileAlloc(b.graph.io, disk, b.graph.arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            files.append(b.allocator, .{ .key = key, .bytes = "" }) catch @panic("OOM");
            return;
        },
        else => std.process.fatal("zig_clap schema {s} could not read {s} ({t})", .{ schemaLabel(root_lp), disk, err }),
    };
    b.dependOnFileContents(root_lp.path(b, disk));
    files.append(b.allocator, .{ .key = key, .bytes = bytes }) catch @panic("OOM");
}

fn schemaCachePath(b: *std.Build, lp: std.Build.LazyPath) std.Build.Cache.Path {
    return switch (lp) {
        .src_path => |sp| sp.owner.root.join(b.graph.arena, sp.sub_path) catch @panic("OOM"),
        .cwd_relative => |p| .initCwd(p),
        .dependency => |dep| dep.dependency.builder.root.join(b.graph.arena, dep.sub_path) catch @panic("OOM"),
        else => std.process.fatal("the args option must be a source directory", .{}),
    };
}

fn schemaLabel(lp: std.Build.LazyPath) []const u8 {
    return switch (lp) {
        .src_path => |sp| sp.sub_path,
        .cwd_relative => |p| p,
        .dependency => |dep| dep.sub_path,
        else => "args",
    };
}

fn childSegments(arena: std.mem.Allocator, csv: []const u8) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, csv, '\n');
    var saw_header = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!saw_header and std.mem.startsWith(u8, line, "long,path,")) {
            saw_header = true;
            continue;
        }
        var index: usize = 0;
        const long = readField(arena, line, &index);
        const path_cell = readField(arena, line, &index);
        const segment = if (path_cell.len == 0) long else path_cell;
        if (segment.len == 0) std.process.fatal("subcommand needs a long name: {s}", .{line});
        if (segment.len > 255) std.process.fatal("subcommand path is longer than 255 bytes: {s}", .{segment});
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) {
            std.process.fatal("subcommand path cannot be '.' or '..'", .{});
        }
        for (segment) |c| {
            if (c == '/' or c == '\\' or c == 0) {
                std.process.fatal("subcommand path must be one directory name: {s}", .{segment});
            }
        }
        list.append(arena, segment) catch @panic("OOM");
    }
    return list.items;
}

fn readField(arena: std.mem.Allocator, line: []const u8, index: *usize) []const u8 {
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
                return unescapeQuotes(arena, body);
            }
            index.* += 1;
        }
        std.process.fatal("unterminated quote: {s}", .{line});
    }

    const start = index.*;
    while (index.* < line.len and line[index.*] != ',') index.* += 1;
    const body = std.mem.trim(u8, line[start..index.*], " \t\r");
    if (index.* < line.len and line[index.*] == ',') index.* += 1;
    return body;
}

fn unescapeQuotes(arena: std.mem.Allocator, body: []const u8) []const u8 {
    const buf = arena.alloc(u8, body.len) catch @panic("OOM");
    var n: usize = 0;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        buf[n] = body[i];
        n += 1;
        if (body[i] == '"' and i + 1 < body.len and body[i + 1] == '"') i += 1;
    }
    return buf[0..n];
}
