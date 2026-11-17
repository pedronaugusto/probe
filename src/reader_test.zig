//! Snapshots: a directory with no commit has none, a manifest whose files
//! stay gone is `Busy` past the retries, a reopen holds again the segments
//! it shares with the snapshot before, and a snapshot reads its documents
//! after the writer removed its files. That a snapshot never changes while
//! the writer goes on is the writer's model property's.
const std = @import("std");
const Writer = @import("Writer.zig");
const Reader = @import("Reader.zig");
const Schema = @import("Schema.zig");
const segment = @import("segment.zig");

const testing = std.testing;
const io = testing.io;

const schema = [_]Schema.Field{
    .{ .name = "body", .kind = .text, .positions = true },
    .{ .name = "serial", .kind = .keyword, .stored = true },
};

/// A document: its id and the serial that tells it apart.
pub const Doc = struct { id: u64, serial: u32 };

pub fn lessThan(_: void, a: Doc, b: Doc) bool {
    return a.id < b.id or (a.id == b.id and a.serial < b.serial);
}

/// What `r` holds, deleted documents left out, sorted: the serial is the
/// last stored field.
pub fn holds(r: *const Reader, read_io: std.Io, gpa: std.mem.Allocator, out: *std.ArrayList(Doc)) !void {
    out.clearRetainingCapacity();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);
    for (r.segments) |*s| {
        const seg = s.read();
        for (0..s.docs()) |d| {
            const doc: u32 = @intCast(d);
            if (s.isDeleted(doc)) continue;
            var values: [1]segment.store.Value = undefined;
            try seg.storedOf(read_io, gpa, doc, &buffer, &values);
            try out.append(gpa, .{ .id = seg.idOf(doc), .serial = try std.fmt.parseInt(u32, values[0].bytes, 10) });
        }
    }
    std.mem.sort(Doc, out.items, {}, lessThan);
}

/// `r` holds exactly `want`, in any order.
pub fn expectHolds(r: *const Reader, want: []const Doc) !void {
    const gpa = testing.allocator;
    const sorted = try gpa.dupe(Doc, want);
    defer gpa.free(sorted);
    std.mem.sort(Doc, sorted, {}, lessThan);
    var got: std.ArrayList(Doc) = .empty;
    defer got.deinit(gpa);
    try holds(r, io, gpa, &got);
    try testing.expectEqualSlices(Doc, sorted, got.items);
}

fn add(w: *Writer, id: u64, serial: u32) !void {
    var serial_text: [10]u8 = undefined;
    const values = [_]segment.write.Value{ .{ .text = "alpha" }, .{ .keyword = try std.mem.print(&serial_text, "{d}", .{serial}) } };
    try w.add(io, .{ .id = id, .values = &values });
}

test "a directory with no commit has no snapshot" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testing.expectError(error.NotFound, Reader.open(testing.allocator, io, tmp.dir, &schema, .{}));
    var w: Writer = try .open(testing.allocator, io, tmp.dir, &schema, .{});
    defer w.deinit(io);
    try add(&w, 1, 0);
    try w.refresh(io);
    try testing.expectError(error.NotFound, Reader.open(testing.allocator, io, tmp.dir, &schema, .{}));
    // The writer's own snapshot holds what it closed.
    var r = try w.reader();
    defer r.deinit();
    try expectHolds(&r, &.{.{ .id = 1, .serial = 0 }});
}

test "a manifest whose segment file stays gone is read again, then Busy" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = try .open(testing.allocator, io, tmp.dir, &schema, .{});
    defer w.deinit(io);
    try add(&w, 1, 0);
    _ = try w.commit(io);
    var name_buffer: [segment.files.max_name_bytes]u8 = undefined;
    try tmp.dir.deleteFile(io, segment.files.name(&name_buffer, 0, .segment, 0));
    for ([_]u8{ 0, 1, 8 }) |retries| {
        try testing.expectError(error.Busy, Reader.open(testing.allocator, io, tmp.dir, &schema, .{ .retries = retries }));
    }
}

test "a reopen holds again the segments it shares, and reads the deletions that changed" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = try .open(testing.allocator, io, tmp.dir, &schema, .{});
    defer w.deinit(io);
    try add(&w, 1, 0);
    try add(&w, 2, 1);
    _ = try w.commit(io);
    var first = try Reader.open(testing.allocator, io, tmp.dir, &schema, .{});
    defer first.deinit();
    try add(&w, 3, 2);
    _ = try w.commit(io);
    var second = try first.reopen(io);
    defer second.deinit();
    try testing.expectEqual(@as(usize, 2), second.segments.len);
    try testing.expectEqual(first.segments[0].held.aegis_block, second.segments[0].held.aegis_block);
    try w.delete(1);
    _ = try w.commit(io);
    var third = try second.reopen(io);
    defer third.deinit();
    try testing.expectEqual(second.segments[0].held.aegis_block, third.segments[0].held.aegis_block);
    try testing.expectEqual(second.segments[1].held.aegis_block, third.segments[1].held.aegis_block);
    try expectHolds(&first, &.{ .{ .id = 1, .serial = 0 }, .{ .id = 2, .serial = 1 } });
    try expectHolds(&second, &.{ .{ .id = 1, .serial = 0 }, .{ .id = 2, .serial = 1 }, .{ .id = 3, .serial = 2 } });
    try expectHolds(&third, &.{ .{ .id = 2, .serial = 1 }, .{ .id = 3, .serial = 2 } });
    try testing.expectEqual(first.generation + 2, third.generation);
}

test "a snapshot reads its documents after the writer removed their files" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = try .open(testing.allocator, io, tmp.dir, &schema, .{ .keep_commits = 1 });
    defer w.deinit(io);
    // Enough documents that their postings and stored fields are read from
    // the file, not from what the snapshot read when it opened.
    var want: [300]Doc = undefined;
    for (&want, 0..) |*d, i| {
        d.* = .{ .id = i, .serial = @intCast(i) };
        try add(&w, d.id, d.serial);
    }
    _ = try w.commit(io);
    var r = try Reader.open(testing.allocator, io, tmp.dir, &schema, .{});
    defer r.deinit();
    for (want) |d| try w.delete(d.id);
    try add(&w, 1000, 1000);
    _ = try w.commit(io);
    var name_buffer: [segment.files.max_name_bytes]u8 = undefined;
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, segment.files.name(&name_buffer, 0, .segment, 0), .{}));
    try expectHolds(&r, &want);
    var newest = try r.reopen(io);
    defer newest.deinit();
    try expectHolds(&newest, &.{.{ .id = 1000, .serial = 1000 }});
}

test "a reopen reads a committed segment that took the number of one a writer's snapshot holds in memory" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var w: Writer = try .open(testing.allocator, io, tmp.dir, &schema, .{});
    _ = try w.commit(io);
    try add(&w, 1, 0);
    try w.refresh(io);
    // Segment 0, in memory, never committed: the writer closes without it.
    var dropped = try w.reader();
    defer dropped.deinit();
    w.deinit(io);
    w = try .open(testing.allocator, io, tmp.dir, &schema, .{});
    defer w.deinit(io);
    try add(&w, 2, 1);
    _ = try w.commit(io);
    var r = try dropped.reopen(io);
    defer r.deinit();
    try expectHolds(&r, &.{.{ .id = 2, .serial = 1 }});
    try expectHolds(&dropped, &.{.{ .id = 1, .serial = 0 }});
}
