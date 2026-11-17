//! A segment file's frame: its name, its header's bytes, and a check that
//! gives back the body and refuses any file that is not this one, whole.
const std = @import("std");
const shakedown = @import("shakedown");
const files = @import("segment.zig").files;
const Files = @import("sources_test.zig").Files;
const Source = @import("segment.zig").source.Source;

const testing = std.testing;
const gen = shakedown.gen;
const io = testing.io;

fn frame(buffer: []u8, kind: files.Kind, segment: u64, body: []const u8) []u8 {
    const h = files.header(kind, segment);
    @memcpy(buffer[0..files.header_bytes], &h);
    @memcpy(buffer[files.header_bytes..][0..body.len], body);
    const end = files.header_bytes + body.len;
    const f = files.footer(files.crc32c(0, buffer[0..end]));
    @memcpy(buffer[end..][0..files.footer_bytes], &f);
    return buffer[0 .. end + files.footer_bytes];
}

fn checked(kind: files.Kind, segment: u64, bytes: []const u8) files.CheckError!files.Body {
    const e: files.Expected = .{ .kind = kind, .segment = segment };
    return e.check(.init(bytes));
}

test "a file's header is its magic, format, kind and segment, little endian" {
    const h = files.header(.postings, 0x0102030405060708);
    try testing.expectEqualSlices(u8, "probeidx" ++ "\x01\x00" ++ "\x02" ++ "\x00\x00\x00\x00\x00" ++ "\x08\x07\x06\x05\x04\x03\x02\x01", &h);
}

test "names: the segment in hex and the kind's extension, deletions with their generation" {
    var buffer: [files.max_name_bytes]u8 = undefined;
    try testing.expectEqualStrings("000000000000002a.terms", files.name(&buffer, 42, .terms, 0));
    try testing.expectEqualStrings("000000000000002a.post", files.name(&buffer, 42, .postings, 0));
    try testing.expectEqualStrings("ffffffffffffffff.del.ffffffffffffffff", files.name(&buffer, std.math.maxInt(u64), .deletions, std.math.maxInt(u64)));
}

test "a file of another kind, segment or newer format, or cut short, is refused" {
    var buffer: [64]u8 = undefined;
    const file = frame(&buffer, .terms, 7, "body");
    try testing.expectEqualStrings("body", (try checked(.terms, 7, file)).bytes);
    try testing.expectError(error.Corrupt, checked(.postings, 7, file));
    try testing.expectError(error.Corrupt, checked(.terms, 8, file));
    try testing.expectError(error.Corrupt, checked(.terms, 7, file[0 .. file.len - 1]));
    try testing.expectError(error.Corrupt, checked(.terms, 7, file[0 .. files.header_bytes + files.footer_bytes - 1]));
    // A newer format, its CRC-32C whole: refused for its version.
    std.mem.writeInt(u16, file[8..10], files.format + 1, .little);
    std.mem.writeInt(u32, file[file.len - 4 ..][0..4], files.crc32c(0, file[0 .. file.len - 4]), .little);
    try testing.expectError(error.VersionTooNew, checked(.terms, 7, file));
    // A zero byte set, its CRC-32C whole.
    std.mem.writeInt(u16, file[8..10], files.format, .little);
    file[13] = 1;
    std.mem.writeInt(u32, file[file.len - 4 ..][0..4], files.crc32c(0, file[0 .. file.len - 4]), .little);
    try testing.expectError(error.Corrupt, checked(.terms, 7, file));
}

fn anyFlip(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var body_buffer: [48]u8 = undefined;
    const body = gen.bytesInto(s, &body_buffer);
    const kind = gen.enumValue(s, files.Kind);
    const segment = gen.int(s, u64);
    var buffer: [80]u8 = undefined;
    const file = frame(&buffer, kind, segment, body);
    try testing.expectEqualSlices(u8, body, (try checked(kind, segment, file)).bytes);
    // Any one bit changed anywhere is refused.
    const at = gen.intRange(s, usize, 0, file.len - 1);
    file[at] ^= @as(u8, 1) << gen.intRange(s, u3, 0, 7);
    if (checked(kind, segment, file)) |_| return error.TestUnexpectedResult else |_| {}
}

test "a file reads back as its body, and with any one bit changed is refused" {
    try shakedown.check(testing.allocator, {}, anyFlip, .{ .seed = 0x66696c65, .cases = 3000 });
}

fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var buffer: [64]u8 = undefined;
    const bytes = gen.bytesInto(s, &buffer);
    const body = checked(gen.enumValue(s, files.Kind), gen.intRange(s, u64, 0, 3), bytes) catch return;
    try testing.expect(body.bytes.len + files.header_bytes + files.footer_bytes == bytes.len);
}

test "fuzz: any bytes are refused as a file, or give a body within them" {
    try shakedown.check(testing.allocator, {}, anyBytes, .{ .seed = 0x66757a7a, .cases = 3000 });
}

fn openedAsChecked(f: *Files, case: *shakedown.Case) anyerror!void {
    defer f.close();
    const s = case.source;
    var body_buffer: [300]u8 = undefined;
    const body = gen.bytesInto(s, &body_buffer);
    const kind = gen.enumValue(s, files.Kind);
    const segment = gen.intRange(s, u64, 0, 3);
    var buffer: [400]u8 = undefined;
    const file = frame(&buffer, kind, segment, body);
    // Changed anywhere, or cut short, or not.
    const change = gen.intRange(s, u8, 0, 3);
    const bytes = switch (change) {
        0 => file,
        1 => file[0..gen.intRange(s, usize, 0, file.len)],
        else => blk: {
            file[gen.intRange(s, usize, 0, file.len - 1)] ^= @as(u8, 1) << gen.intRange(s, u3, 0, 7);
            break :blk file;
        },
    };
    const e: files.Expected = .{ .kind = gen.enumValue(s, files.Kind), .segment = gen.intRange(s, u64, 0, 3) };
    const opened = try f.fileOf(bytes);
    var verify_buffer: [64]u8 = undefined;
    const by_check = e.check(.init(bytes));
    const verify_len = gen.intRange(s, usize, 1, verify_buffer.len);
    const by_open: files.OpenError!Source = blk: {
        const source = e.open(io, opened) catch |err| break :blk err;
        e.verify(io, opened, verify_buffer[0..verify_len]) catch |err| break :blk err;
        break :blk source;
    };
    if (by_check) |checked_body| {
        const source = try by_open;
        var read_back: [300]u8 = undefined;
        try testing.expectEqual(checked_body.bytes.len, source.len());
        try source.read(io, 0, read_back[0..checked_body.bytes.len]);
        try testing.expectEqualSlices(u8, checked_body.bytes, read_back[0..checked_body.bytes.len]);
    } else |err| try testing.expectError(err, by_open);
    // A whole file is refused at its open for its header alone.
    if (change == 0) {
        if (by_check) |_| {} else |err| try testing.expectError(err, e.open(io, opened));
    }
}

test "a file opened and verified is refused or read exactly as a check of its bytes" {
    var f: Files = .init();
    defer f.deinit();
    try shakedown.check(testing.allocator, &f, openedAsChecked, .{ .seed = 0x6f70656e, .cases = 1500 });
}

fn namesBack(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var buffer: [files.max_name_bytes]u8 = undefined;
    const kind = gen.enumValue(s, files.Kind);
    const named: files.Named = .{ .segment = gen.int(s, u64), .kind = kind, .generation = if (kind == .deletions) gen.int(s, u64) else 0 };
    try testing.expectEqual(named, files.parseName(files.name(&buffer, named.segment, named.kind, named.generation)).?);
    // Any entry that parses is that name exactly.
    const model = files.name(&buffer, gen.int(s, u64), gen.enumValue(s, files.Kind), gen.int(s, u64));
    var entry: [files.max_name_bytes + 2]u8 = undefined;
    const len = gen.intRange(s, usize, @max(model.len, 2) - 2, @min(model.len + 2, entry.len));
    for (entry[0..len], 0..) |*c, i| c.* = if (i < model.len and gen.intRange(s, u8, 0, 9) != 0) model[i] else "0aF.delpostx"[gen.intRange(s, usize, 0, 11)];
    var back: [files.max_name_bytes]u8 = undefined;
    if (files.parseName(entry[0..len])) |n| try testing.expectEqualStrings(entry[0..len], files.name(&back, n.segment, n.kind, n.generation));
}

test "a segment file's name and what it names map one to one" {
    try shakedown.check(testing.allocator, {}, namesBack, .{ .seed = 0x6e6d6573, .cases = 5000 });
}
