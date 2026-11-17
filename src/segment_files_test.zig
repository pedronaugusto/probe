//! A segment's files: their names, their headers' bytes, a segment file read
//! back as its sections and a deletions file as its body, and either
//! refused when it is not this file, whole. A segment opened from disk and
//! verified agrees with a check of its bytes.
const std = @import("std");
const shakedown = @import("shakedown");
const files = @import("segment.zig").files;
const Files = @import("sources_test.zig").Files;
const Source = @import("segment.zig").source.Source;

const testing = std.testing;
const gen = shakedown.gen;
const io = testing.io;

/// A deletions file: `body` in its frame.
fn frame(buffer: []u8, segment: u64, body: []const u8) []u8 {
    const h = files.header(.deletions, segment);
    @memcpy(buffer[0..files.header_bytes], &h);
    @memcpy(buffer[files.header_bytes..][0..body.len], body);
    const end = files.header_bytes + body.len;
    const f = files.footer(files.crc32c(0, buffer[0..end]));
    @memcpy(buffer[end..][0..files.footer_bytes], &f);
    return buffer[0 .. end + files.footer_bytes];
}

fn checked(segment: u64, bytes: []const u8) files.CheckError!files.Body {
    const e: files.Expected = .{ .kind = .deletions, .segment = segment };
    return e.check(.init(bytes));
}

/// Sections of any lengths, `pool`'s bytes.
fn sectionsOf(s: *shakedown.Source, pool: []const u8) files.Sections {
    var sections: files.Sections = undefined;
    for (&sections) |*section| {
        const len = gen.intRange(s, usize, 0, 40);
        const start = gen.intRange(s, usize, 0, pool.len - len);
        section.* = pool[start..][0..len];
    }
    return sections;
}

test "a file's header is its magic, format, kind and segment, little endian" {
    const h = files.header(.segment, 0x0102030405060708);
    try testing.expectEqualSlices(u8, "probeidx" ++ "\x01\x00" ++ "\x01" ++ "\x00\x00\x00\x00\x00" ++ "\x08\x07\x06\x05\x04\x03\x02\x01", &h);
}

test "names: the segment in hex, its file .seg, deletions .del with their generation" {
    var buffer: [files.max_name_bytes]u8 = undefined;
    try testing.expectEqualStrings("000000000000002a.seg", files.name(&buffer, 42, .segment, 0));
    try testing.expectEqualStrings("ffffffffffffffff.del.ffffffffffffffff", files.name(&buffer, std.math.maxInt(u64), .deletions, std.math.maxInt(u64)));
}

test "a deletions file of another segment or a newer format, or cut short, is refused" {
    var buffer: [64]u8 = undefined;
    const file = frame(&buffer, 7, "body");
    try testing.expectEqualStrings("body", (try checked(7, file)).bytes);
    try testing.expectError(error.Corrupt, checked(8, file));
    const as_segment: files.Expected = .{ .kind = .segment, .segment = 7 };
    try testing.expectError(error.Corrupt, as_segment.checkSegment(.init(file)));
    try testing.expectError(error.Corrupt, checked(7, file[0 .. file.len - 1]));
    try testing.expectError(error.Corrupt, checked(7, file[0 .. files.header_bytes + files.footer_bytes - 1]));
    // A newer format, its CRC-32C whole: refused for its version.
    std.mem.writeInt(u16, file[8..10], files.format + 1, .little);
    std.mem.writeInt(u32, file[file.len - 4 ..][0..4], files.crc32c(0, file[0 .. file.len - 4]), .little);
    try testing.expectError(error.VersionTooNew, checked(7, file));
    // A zero byte set, its CRC-32C whole.
    std.mem.writeInt(u16, file[8..10], files.format, .little);
    file[13] = 1;
    std.mem.writeInt(u32, file[file.len - 4 ..][0..4], files.crc32c(0, file[0 .. file.len - 4]), .little);
    try testing.expectError(error.Corrupt, checked(7, file));
}

fn segmentFlip(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var pool: [256]u8 = undefined;
    for (&pool, 0..) |*b, i| b.* = @truncate(i *% 37);
    const sections = sectionsOf(s, &pool);
    const segment = gen.int(s, u64);
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    try files.appendSegment(gpa, &file, segment, &sections);
    const e: files.Expected = .{ .kind = .segment, .segment = segment };
    const back = try e.checkSegment(.init(file.items));
    for (sections, back) |want, got| try testing.expectEqualSlices(u8, want, got);
    // Any one bit changed anywhere is refused.
    file.items[gen.intRange(s, usize, 0, file.items.len - 1)] ^= @as(u8, 1) << gen.intRange(s, u3, 0, 7);
    if (e.checkSegment(.init(file.items))) |_| return error.TestUnexpectedResult else |_| {}
}

test "a segment file reads back as its sections, and with any one bit changed is refused" {
    try shakedown.check(testing.allocator, {}, segmentFlip, .{ .seed = 0x73656766, .cases = 3000 });
}

fn deletionsFlip(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var body_buffer: [48]u8 = undefined;
    const body = gen.bytesInto(s, &body_buffer);
    const segment = gen.int(s, u64);
    var buffer: [80]u8 = undefined;
    const file = frame(&buffer, segment, body);
    try testing.expectEqualSlices(u8, body, (try checked(segment, file)).bytes);
    // Any one bit changed anywhere is refused.
    const at = gen.intRange(s, usize, 0, file.len - 1);
    file[at] ^= @as(u8, 1) << gen.intRange(s, u3, 0, 7);
    if (checked(segment, file)) |_| return error.TestUnexpectedResult else |_| {}
}

test "a deletions file reads back as its body, and with any one bit changed is refused" {
    try shakedown.check(testing.allocator, {}, deletionsFlip, .{ .seed = 0x66696c65, .cases = 3000 });
}

fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var buffer: [256]u8 = undefined;
    const bytes = gen.bytesInto(s, &buffer);
    const segment = gen.intRange(s, u64, 0, 3);
    if (checked(segment, bytes)) |body| {
        try testing.expect(body.bytes.len + files.header_bytes + files.footer_bytes == bytes.len);
    } else |_| {}
    const e: files.Expected = .{ .kind = .segment, .segment = segment };
    const sections = e.checkSegment(.init(bytes)) catch return;
    // Sections that lie end to end inside the file, between its frame.
    var total: usize = files.header_bytes + files.table_bytes + files.footer_bytes;
    for (sections) |section| total += section.len;
    try testing.expectEqual(bytes.len, total);
}

test "fuzz: any bytes are refused as a file, or give sections or a body within them" {
    try shakedown.check(testing.allocator, {}, anyBytes, .{ .seed = 0x66757a7a, .cases = 3000 });
}

fn openedAsChecked(f: *Files, case: *shakedown.Case) anyerror!void {
    defer f.close();
    const s = case.source;
    const gpa = testing.allocator;
    var pool: [256]u8 = undefined;
    for (&pool, 0..) |*b, i| b.* = @truncate(i *% 41);
    const sections = sectionsOf(s, &pool);
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    try files.appendSegment(gpa, &file, gen.intRange(s, u64, 0, 3), &sections);
    // Changed anywhere, or cut short, or not.
    const change = gen.intRange(s, u8, 0, 3);
    const bytes = switch (change) {
        0 => file.items,
        1 => file.items[0..gen.intRange(s, usize, 0, file.items.len)],
        else => blk: {
            file.items[gen.intRange(s, usize, 0, file.items.len - 1)] ^= @as(u8, 1) << gen.intRange(s, u3, 0, 7);
            break :blk file.items;
        },
    };
    const e: files.Expected = .{ .kind = .segment, .segment = gen.intRange(s, u64, 0, 3) };
    const opened = try f.fileOf(bytes);
    var verify_buffer: [64]u8 = undefined;
    const by_check = e.checkSegment(.init(bytes));
    const verify_len = gen.intRange(s, usize, 1, verify_buffer.len);
    const by_open: files.OpenError!files.Table = blk: {
        const table = e.openSegment(io, opened) catch |err| break :blk err;
        e.verify(io, opened, verify_buffer[0..verify_len]) catch |err| break :blk err;
        break :blk table;
    };
    if (by_check) |checked_sections| {
        const table = try by_open;
        const whole: Source = .{ .file = .{ .file = .of(opened), .start = 0, .len = bytes.len } };
        for (checked_sections, std.enums.values(files.Section)) |want, section| {
            const entry = table.of(section);
            var read_back: [64]u8 = undefined;
            try testing.expectEqual(want.len, entry.len);
            try whole.read(io, entry.offset, read_back[0..want.len]);
            try testing.expectEqualSlices(u8, want, read_back[0..want.len]);
        }
    } else |err| try testing.expectError(err, by_open);
    // A whole file another segment's is refused at its open, for its header.
    if (change == 0) {
        if (by_check) |_| {} else |err| try testing.expectError(err, e.openSegment(io, opened));
    }
}

test "a segment opened and verified is refused or read exactly as a check of its bytes" {
    var f: Files = .init();
    defer f.deinit();
    try shakedown.check(testing.allocator, &f, openedAsChecked, .{ .seed = 0x6f70656e, .cases = 1500 });
}

test "a segment with a section changed opens, and is refused by its section's check and by verify" {
    var f: Files = .init();
    defer f.deinit();
    const gpa = testing.allocator;
    const sections: files.Sections = .{ "postings", "store", "dictionary", "lengths", "columns", "ids" };
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    try files.appendSegment(gpa, &file, 5, &sections);
    // A byte of the postings section changed.
    const postings_at = files.header_bytes;
    file.items[postings_at + 1] ^= 0xff;
    const opened = try f.fileOf(file.items);
    const e: files.Expected = .{ .kind = .segment, .segment = 5 };
    const table = try e.openSegment(io, opened);
    try testing.expectError(error.Corrupt, table.checkSection(.postings, file.items[postings_at..][0..sections[0].len]));
    var buffer: [16]u8 = undefined;
    try testing.expectError(error.Corrupt, e.verify(io, opened, &buffer));
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
    for (entry[0..len], 0..) |*c, i| c.* = if (i < model.len and gen.intRange(s, u8, 0, 9) != 0) model[i] else "0aF.delsegx"[gen.intRange(s, usize, 0, 10)];
    var back: [files.max_name_bytes]u8 = undefined;
    if (files.parseName(entry[0..len])) |n| try testing.expectEqualStrings(entry[0..len], files.name(&back, n.segment, n.kind, n.generation));
}

test "a file's name and what it names map one to one" {
    try shakedown.check(testing.allocator, {}, namesBack, .{ .seed = 0x6e6d6573, .cases = 5000 });
}

test "a segment with bytes between its sections and its table is refused" {
    const gpa = testing.allocator;
    const sections: files.Sections = .{ "postings", "store", "dictionary", "lengths", "columns", "ids" };
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    try files.appendSegment(gpa, &file, 5, &sections);
    // A byte after the last section: the table and its CRC-32C unchanged.
    try file.insert(gpa, file.items.len - files.table_bytes - files.footer_bytes, 0);
    const e: files.Expected = .{ .kind = .segment, .segment = 5 };
    try testing.expectError(error.Corrupt, e.checkSegment(.init(file.items)));
}
