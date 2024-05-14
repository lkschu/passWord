const std = @import("std");
const zap = @import("zap");
const print = std.debug.print;

var allocator: std.mem.Allocator = undefined;

var rand: std.rand.Xoshiro256 = undefined;

// const data_english = @embedFile("./english_words.txt");
// const data_german = @embedFile("./german_words.txt");
// const data_french = @embedFile("./french_words.txt");

const ValueError = error{
    InvalidInput,
    ValueTooBig,
    ValueTooSmall,
    NotEnoughValues,
    UnknownValue,
};

const api_params = struct {
    n: u16,
    min: u16,
    max: u16,
    fn default() api_params {
        return .{ .n = 5, .min = 4, .max = 9 };
    }
    /// manual param decoding (can be done faster in zap)
    fn parse_params(s: []u8) !api_params {
        errdefer print("Error when parsing params\n", .{});
        const fields = enum { min, max, n };
        var ret = api_params.default();
        var iter = std.mem.split(u8, s, "&");

        while (iter.next()) |para| {
            var inner_iter = std.mem.split(u8, para, "=");
            const p = std.meta.stringToEnum(fields, inner_iter.next() orelse return ValueError.UnknownValue) orelse return ValueError.UnknownValue;
            const v = inner_iter.next() orelse return ValueError.UnknownValue;
            switch (p) {
                .min => ret.min = try std.fmt.parseInt(u16, v, 10),
                .max => ret.max = try std.fmt.parseInt(u16, v, 10),
                .n => ret.n = try std.fmt.parseInt(u16, v, 10),
            }
        }
        return ret;
    }
};

/// open and return the corresponding wordlist to the given input
pub fn select_file(inp: []const u8) !std.fs.File {
    const path = inp;

    const Languages = enum { de, en, fr };
    const l = std.meta.stringToEnum(Languages, path) orelse return ValueError.InvalidInput;
    return switch (l) {
        .en => try std.fs.cwd().openFile("./src/english_words.txt", .{}),
        .de => try std.fs.cwd().openFile("./src/german_words.txt", .{}),
        .fr => try std.fs.cwd().openFile("./src/french_words.txt", .{}),
    };
}

/// read wordlist and return randomly selected words
pub fn read_file(n: u32, f: std.fs.File, min: u16, max: u16) !std.ArrayList(u8) {
    errdefer print("Error when reading_file\n", .{});
    if (min < 3) {
        return ValueError.ValueTooSmall;
    }
    if (max > 16) {
        return ValueError.ValueTooSmall;
    }
    if (max <= min) {
        return ValueError.ValueTooSmall;
    }

    var _buffered = std.io.bufferedReader(f.reader());
    var reader = _buffered.reader();

    var read_buffer = std.ArrayList(u8).init(allocator);
    defer read_buffer.deinit();
    var file_buffer = std.ArrayList(u8).init(allocator);
    defer file_buffer.deinit();
    var word_start = std.ArrayList(u64).init(allocator);
    defer word_start.deinit();
    var word_len = std.ArrayList(u64).init(allocator);
    defer word_len.deinit();
    var output = std.ArrayList(u8).init(allocator);
    // defer output.deinit();

    var line_count_max: u64 = 0;
    var bytes_count: u64 = 0;

    while (true) {
        reader.streamUntilDelimiter(read_buffer.writer(), '\n', null) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try read_buffer.append('\n');
        try file_buffer.appendSlice(read_buffer.items);
        try word_start.append(bytes_count);
        try word_len.append(read_buffer.items.len - 1);
        line_count_max += 1;
        bytes_count += read_buffer.items.len;
        read_buffer.clearRetainingCapacity();
    }
    // add last element
    try file_buffer.appendSlice(read_buffer.items);
    try word_start.append(bytes_count);
    try word_len.append(read_buffer.items.len);

    for (0..n) |_| {
        var rnd = @mod(rand.random().int(u32), line_count_max);
        var max_iter: i32 = 1000;
        while (word_len.items[rnd] < min or word_len.items[rnd] > max) {
            rnd = @mod(rand.random().int(u32), line_count_max);
            max_iter -= 1;
            if (max_iter < 0) {
                return ValueError.NotEnoughValues;
            }
        }
        try output.appendSlice(file_buffer.items[word_start.items[rnd] .. word_start.items[rnd] + word_len.items[rnd]]);
        try output.append(' ');
    }
    return output;
}

/// on error return the "default" page
fn on_error(r: zap.Request) void {
    r.setHeader("Content-Type", "text/html; charset=UTF-8") catch return;
    r.sendBody("<html><body><h1>passWord</h1>API example: <tt>../en?min=4&max=8&n=6</tt> where min/max limits the word" ++
        " length and n denotes the amount of words returned. <ul> <li><a href=\"./en?min=4&max=8&n=6\">english</a></li>" ++
        " <li><a href=\"./de?min=4&max=8&n=6\">deutsch</a></li> <li><a href=\"./fr?min=4&max=8&n=6\">français</a></li>" ++
        " </ul></body></html>") catch return;
}

fn on_request(r: zap.Request) void {
    if (r.methodAsEnum() != .GET) return;

    if (r.path) |path| {
        var the_path = path;

        // Clean url path of '/'
        while (the_path.len > 1 and the_path[0] == '/') {
            the_path = the_path[1..];
        }
        while (the_path.len > 1 and the_path[the_path.len - 1] == '/') {
            the_path = the_path[0 .. the_path.len - 1];
        }

        if (select_file(the_path)) |the_file| {
            defer the_file.close();
            var param: api_params = undefined;
            if (r.query) |q| {
                param = api_params.parse_params(@constCast(q)) catch return on_error(r);
            } else {
                param = api_params.default();
            }
            const buff = read_file(param.n, the_file, param.min, param.max) catch return on_error(r);
            const str_buf: []u8 = buff.items;
            r.setHeader("Content-Type", "text/plain; charset=UTF-8") catch return on_error(r);
            r.sendBody(str_buf) catch return on_error(r);
        } else |_| {
            on_error(r);
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    allocator = gpa.allocator();

    //init rng
    const stamp: u64 = @intCast(std.time.milliTimestamp());
    rand = std.rand.DefaultPrng.init(stamp);

    // scope to detect possible memory leaks
    {
        var listener = zap.HttpListener.init(.{
            .port = 3355,
            .on_request = on_request,
            .log = false,
            // .max_clients = 1000,
        });
        try listener.listen();

        print("Listening on 0.0.0.0:3355\n", .{});

        zap.start(.{
            .threads = 24,
            .workers = 24,
        });
    }
    const has_leaked = gpa.detectLeaks();
    std.log.debug("Has leaked: {}\n", .{has_leaked});
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
