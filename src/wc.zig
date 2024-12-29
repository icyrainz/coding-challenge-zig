const std = @import("std");
const clap = @import("clap");

const stdout = std.io.getStdOut().writer();

const WcFlags = struct {
    count_bytes: bool = false,
    count_lines: bool = false,
    count_words: bool = false,
    count_chars: bool = false,
};

const WcResult = struct {
    count_bytes: ?usize = null,
    count_lines: ?usize = null,
    count_words: ?usize = null,
    count_chars: ?usize = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-c                     Count bytes
        \\-l                     Count lines
        \\-w                     Count words
        \\-m                     Count characters
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
    if (res.args.help != 0) {
        std.debug.print("--help\n", .{});
        return;
    }

    var wc_flags: WcFlags = .{};

    if (res.args.c != 0) wc_flags.count_bytes = true;
    if (res.args.l != 0) wc_flags.count_lines = true;
    if (res.args.w != 0) wc_flags.count_words = true;

    for (res.positionals[0]) |pos| {
        file_path = pos;
    }

    if (res.args.m != 0) {
        wc_flags.count_chars = true;
    }
    // Toggle all if no flags are defined
    else if (res.args.c == 0 and res.args.l == 0 and res.args.w == 0) {
        wc_flags.count_bytes = true;
        wc_flags.count_lines = true;
        wc_flags.count_words = true;
    }

    const file_content = try openFile(file_path, allocator);
    defer _ = allocator.free(file_content);
    const wc_result = count(file_content, wc_flags);
    const print_wc_result = try printResult(wc_result, allocator);
    defer _ = allocator.free(print_wc_result);

    try stdout.print("{s}\t{s}\n", .{ print_wc_result, file_path });
}

fn openFile(file_path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        std.debug.print("Error opening file: {s}", .{file_path});
        return err;
    };
    const file_content_bytes = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer file.close();

    return file_content_bytes;
}

fn count(file_content_bytes: []const u8, wc_flags: WcFlags) WcResult {
    const LINE_BREAK = '\n';
    var wc_result: WcResult = .{};
    var is_in_word = false;

    if (wc_flags.count_bytes) wc_result.count_bytes = file_content_bytes.len;
    if (wc_flags.count_lines) wc_result.count_lines = 0;
    if (wc_flags.count_words) wc_result.count_words = 0;
    if (wc_flags.count_chars) wc_result.count_chars = 0;

    for (file_content_bytes) |byte| {
        if (wc_flags.count_lines) {
            wc_result.count_lines.? += if (byte == LINE_BREAK) 1 else 0;
        }

        if (wc_flags.count_words) {
            const is_white_space = switch (byte) {
                ' ', '\t', '\n', '\r' => true,
                else => false,
            };

            if (is_in_word and is_white_space) {
                is_in_word = false;
                wc_result.count_words.? += 1;
            } else if (!is_in_word and !is_white_space) {
                is_in_word = true;
            }
        }
    }

    if (is_in_word) {
        wc_result.count_words.? += 1;
    }

    if (wc_flags.count_chars) {
        var utf8_iter = std.unicode.Utf8View.initUnchecked(file_content_bytes).iterator();
        wc_result.count_chars = 0;

        while (utf8_iter.nextCodepoint()) |_| {
            wc_result.count_chars.? += 1;
        }
    }

    return wc_result;
}

fn printResult(wc_result: WcResult, allocator: std.mem.Allocator) ![]const u8 {
    var values = std.ArrayList(usize).init(allocator);
    defer _ = values.deinit();

    if (wc_result.count_bytes) |c| {
        try values.append(c);
    }

    if (wc_result.count_lines) |l| {
        try values.append(l);
    }

    if (wc_result.count_words) |w| {
        try values.append(w);
    }

    if (wc_result.count_chars) |m| {
        try values.append(m);
    }

    var print_result = std.ArrayList(u8).init(allocator);
    const writer = print_result.writer();

    for (values.items, 0..) |value, i| {
        if (i > 0) try writer.writeByte('\t');
        try writer.print("{d}", .{value});
    }

    return print_result.toOwnedSlice();
}

test "count words" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const test_data = "abc 123\t567\nxyz";
    const wc_result = count(test_data, .{ .count_words = true });
    try std.testing.expectEqual(4, wc_result.count_words);
}
