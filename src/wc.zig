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

/// This implementation reads the entire input file in memory and perform single pass to get
/// the count (two passes if character count is required).
/// TODO: Add streaming capability for input file larger than available memory.
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

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
        .allocator = allocator,
    }) catch |err| {
        // Report useful error and exit.
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    var file_path: ?[]const u8 = null;
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

    const content: []const u8 = try readFileContent(file_path, allocator);

    const wc_result = count(content, wc_flags);
    const print_wc_result = try printResult(wc_result, allocator);

    try stdout.print("{s}\t{s}\n", .{ print_wc_result, file_path orelse "stdin" });
}

/// Opens and reads the entire content of a file at the given path.
/// Memory for the file content is allocated using the provided allocator
/// and must be freed by the caller.
///
/// Arguments:
///   file_path: Optional path to the file to read. If null, stdin will be used.
///   allocator: Memory allocator to use
///
/// Returns: The file contents as a byte slice
fn readFileContent(file_path: ?[]const u8, allocator: std.mem.Allocator) ![]const u8 {
    var content: []const u8 = undefined;
    if (file_path) |path| {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.debug.print("Error opening file: {s}", .{path});
            return err;
        };
        content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer file.close();
    } else {
        content = try std.io.getStdIn().readToEndAlloc(allocator, std.math.maxInt(usize));
    }

    return content;
}

/// Counts various metrics (bytes, lines, words, characters) in the given content
/// based on the specified flags.
///
/// Arguments:
///   file_content_bytes: Content to analyze as a byte slice
///   wc_flags: Struct specifying which metrics to count
///
/// Notes:
///   - Uses a single pass for bytes, lines, and words counting
///   - Uses a separate pass for UTF-8 character counting when -m is specified
///   - Words are delimited by spaces, tabs, and newlines
fn count(file_content_bytes: []const u8, wc_flags: WcFlags) WcResult {
    const LINE_BREAK = '\n';
    var wc_result: WcResult = .{};
    var is_in_word = false;

    if (wc_flags.count_bytes) wc_result.count_bytes = file_content_bytes.len;
    if (wc_flags.count_lines) wc_result.count_lines = 0;
    if (wc_flags.count_words) wc_result.count_words = 0;
    if (wc_flags.count_chars) wc_result.count_chars = 0;

    // First pass: count bytes, lines, and words
    // This is done in a single iteration for efficiency
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

    // Second pass: only for character counting
    // This needs separate UTF-8 aware iteration
    if (wc_flags.count_chars) {
        var utf8_iter = std.unicode.Utf8View.initUnchecked(file_content_bytes).iterator();
        wc_result.count_chars = 0;

        while (utf8_iter.nextCodepoint()) |_| {
            wc_result.count_chars.? += 1;
        }
    }

    return wc_result;
}

/// Formats the counting results into a string suitable for output.
/// Results are tab-separated and only includes metrics that were counted.
///
/// Arguments:
///   wc_result: The counting results to format
///   allocator: Memory allocator to use
///
/// Returns: A newly allocated string that must be freed by the caller
fn printResult(wc_result: WcResult, allocator: std.mem.Allocator) ![]const u8 {
    var values = std.ArrayList(usize).init(allocator);
    defer _ = values.deinit();

    if (wc_result.count_bytes) |c| try values.append(c);
    if (wc_result.count_lines) |l| try values.append(l);
    if (wc_result.count_words) |w| try values.append(w);
    if (wc_result.count_chars) |m| try values.append(m);

    var print_result = std.ArrayList(u8).init(allocator);
    const writer = print_result.writer();

    for (values.items, 0..) |value, i| {
        if (i > 0) try writer.writeByte('\t');
        try writer.print("{d}", .{value});
    }

    return print_result.toOwnedSlice();
}

test "byte counting" {
    const TestCase = struct {
        input: []const u8,
        expected: usize,
    };

    const test_cases = [_]TestCase{
        .{ .input = "", .expected = 0 },
        .{ .input = "hello", .expected = 5 },
        .{ .input = "hello\n", .expected = 6 },
        .{ .input = "héllo", .expected = 6 }, // é is 2 bytes in UTF-8
        .{ .input = "👋", .expected = 4 }, // emoji is 4 bytes
    };

    for (test_cases) |tc| {
        const result = count(tc.input, .{ .count_bytes = true });
        try std.testing.expectEqual(@as(?usize, tc.expected), result.count_bytes);
    }
}

test "line counting" {
    const TestCase = struct {
        input: []const u8,
        expected: usize,
    };

    const test_cases = [_]TestCase{
        .{ .input = "", .expected = 0 },
        .{ .input = "hello", .expected = 0 },
        .{ .input = "hello\n", .expected = 1 },
        .{ .input = "hello\nworld", .expected = 1 },
        .{ .input = "hello\nworld\n", .expected = 2 },
        .{ .input = "\n\n\n", .expected = 3 },
        .{ .input = "héllo\n世界\n", .expected = 2 },
    };

    for (test_cases) |tc| {
        const result = count(tc.input, .{ .count_lines = true });
        try std.testing.expectEqual(@as(?usize, tc.expected), result.count_lines);
    }
}

test "word counting" {
    const TestCase = struct {
        input: []const u8,
        expected: usize,
    };

    const test_cases = [_]TestCase{
        .{ .input = "", .expected = 0 },
        .{ .input = "hello", .expected = 1 },
        .{ .input = "hello world", .expected = 2 },
        .{ .input = "hello  world", .expected = 2 }, // multiple spaces
        .{ .input = "hello\tworld", .expected = 2 }, // tab
        .{ .input = "hello\nworld", .expected = 2 }, // newline
        .{ .input = "hello\r\nworld", .expected = 2 }, // CRLF
        .{ .input = "  hello  world  ", .expected = 2 }, // leading/trailing spaces
        .{ .input = "héllo 世界", .expected = 2 }, // unicode
    };

    for (test_cases) |tc| {
        const result = count(tc.input, .{ .count_words = true });
        try std.testing.expectEqual(@as(?usize, tc.expected), result.count_words);
    }
}

test "character counting" {
    const TestCase = struct {
        input: []const u8,
        expected: usize,
    };

    const test_cases = [_]TestCase{
        .{ .input = "", .expected = 0 },
        .{ .input = "hello", .expected = 5 },
        .{ .input = "héllo", .expected = 5 }, // é is one character
        .{ .input = "👋hello", .expected = 6 }, // emoji is one character
        .{ .input = "世界", .expected = 2 }, // two Chinese characters
        .{ .input = "café", .expected = 4 }, // accented character
        .{ .input = "🏳️‍🌈", .expected = 4 }, // complex emoji (rainbow flag)
    };

    for (test_cases) |tc| {
        const result = count(tc.input, .{ .count_chars = true });
        try std.testing.expectEqual(@as(?usize, tc.expected), result.count_chars);
    }
}

test "multiple flags" {
    const test_input = "hello\nworld\n你好\n";

    // Test all flags together
    {
        const result = count(test_input, .{
            .count_bytes = true,
            .count_lines = true,
            .count_words = true,
            .count_chars = true,
        });
        try std.testing.expectEqual(@as(?usize, 19), result.count_bytes);
        try std.testing.expectEqual(@as(?usize, 3), result.count_lines);
        try std.testing.expectEqual(@as(?usize, 3), result.count_words);
        try std.testing.expectEqual(@as(?usize, 15), result.count_chars);
    }

    // Test different combinations
    {
        const result = count(test_input, .{ .count_bytes = true, .count_lines = true });
        try std.testing.expectEqual(@as(?usize, 19), result.count_bytes);
        try std.testing.expectEqual(@as(?usize, 3), result.count_lines);
        try std.testing.expectEqual(@as(?usize, null), result.count_words);
        try std.testing.expectEqual(@as(?usize, null), result.count_chars);
    }
}

test "print result formatting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test single flag
    {
        const result = WcResult{
            .count_bytes = 42,
            .count_lines = null,
            .count_words = null,
            .count_chars = null,
        };
        const output = try printResult(result, allocator);
        try std.testing.expectEqualStrings("42", output);
    }

    // Test multiple flags
    {
        const result = WcResult{
            .count_bytes = 42,
            .count_lines = 5,
            .count_words = 10,
            .count_chars = null,
        };
        const output = try printResult(result, allocator);
        try std.testing.expectEqualStrings("42\t5\t10", output);
    }
}
