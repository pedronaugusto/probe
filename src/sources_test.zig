//! A body read through a window gives its bytes whether it comes from
//! memory or from a file read positionally, a range past it is refused,
//! and a file cut short under an open reader is refused; and `Files`, the
//! other tests' way to give a reader its body from either.
const std = @import("std");
const shakedown = @import("shakedown");
const source = @import("segment.zig").source;

const testing = std.testing;
const gen = shakedown.gen;
const io = testing.io;
const Source = source.Source;
const Window = source.Window;

/// Bodies given to readers as sources: from memory, or written to a file in
/// a temporary directory and read positionally, the file kept open until
/// `close`.
pub const Files = struct {
    tmp: testing.TmpDir,
    open: std.ArrayList(std.Io.File) = .empty,
    made: u32 = 0,

    pub fn init() Files {
        return .{ .tmp = testing.tmpDir(.{}) };
    }

    pub fn deinit(f: *Files) void {
        f.close();
        f.open.deinit(testing.allocator);
        f.tmp.cleanup();
    }

    /// `bytes` as a source: from a file when `file`, else from memory.
    pub fn source(f: *Files, bytes: []const u8, file: bool) !Source {
        if (!file) return .{ .memory = bytes };
        return .{ .file = .{ .file = .of(try f.fileOf(bytes)), .start = 0, .len = bytes.len } };
    }

    /// `bytes` written to a file of their own, opened to read.
    pub fn fileOf(f: *Files, bytes: []const u8) !std.Io.File {
        var name_buffer: [16]u8 = undefined;
        const name = try std.mem.print(&name_buffer, "{d}", .{f.made});
        f.made += 1;
        try f.tmp.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
        const opened = try f.tmp.dir.openFile(io, name, .{});
        errdefer opened.close(io);
        try f.open.append(testing.allocator, opened);
        return opened;
    }

    /// Closes every file opened so far.
    pub fn close(f: *Files) void {
        for (f.open.items) |file| file.close(io);
        f.open.clearRetainingCapacity();
    }
};

fn sameBytes(files: *Files, case: *shakedown.Case) anyerror!void {
    defer files.close();
    const s = case.source;
    var body_buffer: [600]u8 = undefined;
    const body = gen.bytesInto(s, &body_buffer);
    // A part of a file, as a segment file's body sits between its header
    // and its footer.
    const before = gen.intRange(s, usize, 0, 30);
    var framed: [700]u8 = undefined;
    for (framed[0..before]) |*b| b.* = 0xAA;
    @memcpy(framed[before..][0..body.len], body);
    framed[before + body.len] = 0xBB;
    const from_file = try files.source(framed[0 .. before + body.len + 1], true);
    const file_source: Source = .{ .file = .{ .file = from_file.file.file, .start = before, .len = body.len } };
    var buffer: [64]u8 = undefined;
    const window_len = gen.intRange(s, usize, 1, buffer.len);
    var memory: Window = .init(.{ .memory = body }, io);
    var file: Window = .init(file_source, io);
    var at: u64 = 0;
    for (0..gen.intRange(s, usize, 1, 40)) |_| {
        // Mostly forward, as a reader goes; sometimes anywhere.
        at = if (gen.intRange(s, u8, 0, 4) == 0) gen.intRange(s, u64, 0, body.len + 2) else at + gen.intRange(s, u64, 0, 20);
        const n = gen.intRange(s, usize, 0, window_len);
        const want = memory.bytes(&buffer, at, n);
        const got = file.bytes(buffer[0..window_len], at, n);
        if (want) |w| {
            try testing.expectEqualSlices(u8, body[@intCast(at)..][0..n], w);
            try testing.expectEqualSlices(u8, w, try got);
        } else |err| {
            try testing.expectEqual(error.Corrupt, err);
            try testing.expectError(error.Corrupt, got);
        }
        const end = gen.intRange(s, u64, 0, body.len + 2);
        const up_memory = memory.upTo(&buffer, at, n, end);
        const up_file = file.upTo(buffer[0..window_len], at, n, end);
        if (up_memory) |w| {
            try testing.expectEqual(@min(n, end - at), w.len);
            try testing.expectEqualSlices(u8, w, try up_file);
        } else |err| try testing.expectError(err, up_file);
    }
}

test "a window gives a body's bytes alike from memory and from a file, and refuses a range past it" {
    var files: Files = .init();
    defer files.deinit();
    try shakedown.check(testing.allocator, &files, sameBytes, .{ .seed = 0x77696e64, .cases = 500 });
}

test "a file cut short under an open reader is refused, not read past" {
    var files: Files = .init();
    defer files.deinit();
    const bytes = "0123456789abcdef";
    const s = try files.source(bytes, true);
    try files.tmp.dir.writeFile(io, .{ .sub_path = "0", .data = bytes[0..4] });
    var out: [8]u8 = undefined;
    try testing.expectError(error.Corrupt, s.read(io, 2, &out));
    var buffer: [8]u8 = undefined;
    var w: Window = .init(s, io);
    try testing.expectError(error.Corrupt, w.bytes(&buffer, 0, 8));
}
