// ---------------------------------------------------------------------------
// Example usage (in main.zig)
// ---------------------------------------------------------------------------

const std = @import("std");
const zig_clap = @import("zig_clap");

// const csv = @embedFile("args.csv");
const csv =
    \\short,long,type,arity,default,help
    \\v,verbose,bool,0,false,Enable verbose output
    \\b,backup,bool,0,false,Create a backup
    \\p,port,u16,1,8080,Listen port
    \\o,output,?[]const u8,1,null,Optional output file
    \\f,file,[]const u8,+, ,One or more input files
;

pub const defs = zig_clap.parseCsv(csv);
pub const Result = zig_clap.makeResultType(defs);

// In main:
 pub fn main() !void {
     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
     defer _ = gpa.deinit();
     const allocator = gpa.allocator();

     const argv = try std.process.argsAlloc(allocator);
     defer std.process.argsFree(allocator, argv);

     const args = try zig_clap.parse(defs, Result, allocator, argv);
     std.debug.print("port = {d}\n", .{args.port});
     std.debug.print("verbose = {}\n", .{args.verbose});
 }
