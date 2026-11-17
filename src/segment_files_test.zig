//! A segment file's frame: its name, its header's bytes, and a check that
//! gives back the body and refuses any file that is not this one, whole.
const std = @import("std");
const shakedown = @import("shakedown");
const files = @import("segment.zig").files;

const testing = std.testing;
const gen = shakedown.gen;

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
