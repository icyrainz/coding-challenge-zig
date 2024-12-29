const std = @import("std");
const clap = @import("clap");

const stdout = std.io.getStdOut().writer();

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\<str>...
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = gpa.allocator(),
    }) catch |err| {
        // Report useful error and exit.
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    var file_path: []const u8 = undefined;
    if (res.args.help != 0)
        std.debug.print("--help\n", .{});
    for (res.positionals[0]) |pos| {
        file_path = pos;
    }

    const file_content = try openFile(file_path, allocator);
    defer _ = allocator.free(file_content);
    const file_content_bytes_count = countBytes(file_content);

    try stdout.print("{d} {s}\n", .{ file_content_bytes_count, file_path });
}

fn openFile(file_path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const file = try std.fs.cwd().openFile(file_path, .{});

    const file_content_bytes = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    return file_content_bytes;
}

fn countBytes(file_content_bytes: []const u8) usize {
    return file_content_bytes.len;
}
