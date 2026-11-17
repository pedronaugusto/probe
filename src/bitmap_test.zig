//! Deletion sets against a list of doc ids: written and read back the same,
//! one spelling for a set, and any bytes refused or read within bounds.
const std = @import("std");
const shakedown = @import("shakedown");
const bitmap = @import("probe.zig").bitmap;

const testing = std.testing;
const gen = shakedown.gen;

fn againstList(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    const docs = gen.intRange(s, u32, 0, 300);
    var set = try bitmap.Bitmap.init(gpa, docs);
    defer set.deinit(gpa);
    var model: [300]bool = @splat(false);
    if (docs != 0) for (0..gen.intRange(s, usize, 0, 100)) |_| {
        const doc = gen.intRange(s, u32, 0, docs - 1);
        set.add(doc);
        model[doc] = true;
    };
    const bytes = try gpa.alloc(u8, bitmap.bytesFor(docs));
    defer gpa.free(bytes);
    set.write(bytes);
    const view = try bitmap.View.parse(bytes, docs);
    var held: u32 = 0;
    for (0..docs) |doc| {
        try testing.expectEqual(model[doc], view.has(@intCast(doc)));
        try testing.expectEqual(model[doc], set.has(@intCast(doc)));
        held += @intFromBool(model[doc]);
    }
    try testing.expectEqual(held, view.count());
    try testing.expectEqual(held, set.count());
    // A generation started from this one holds the same.
    var next = try bitmap.Bitmap.fromView(gpa, view);
    defer next.deinit(gpa);
    try testing.expectEqualSlices(u64, set.words, next.words);
}

test "a set written reads back as the doc ids added, and a generation starts from it" {
    try shakedown.check(testing.allocator, {}, againstList, .{ .seed = 0x62697473, .cases = 2000 });
}

test "a bit past the last doc, or bytes of another length, are refused" {
    var bytes: [16]u8 = @splat(0);
    _ = try bitmap.View.parse(&bytes, 70);
    bytes[8] = 1 << 6;
    try testing.expectError(error.Corrupt, bitmap.View.parse(&bytes, 70));
    try testing.expectError(error.Corrupt, bitmap.View.parse(bytes[0..8], 70));
    try testing.expectError(error.Corrupt, bitmap.View.parse(&bytes, 200));
}

fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    var buffer: [64]u8 = undefined;
    const bytes = gen.bytesInto(s, &buffer);
    const docs = gen.intRange(s, u32, 0, 512);
    const view = bitmap.View.parse(bytes, docs) catch return;
    for (0..docs) |doc| _ = view.has(@intCast(doc));
    try testing.expect(view.count() <= docs);
}

test "fuzz: any bytes are refused as a set, or read within its docs" {
    try shakedown.check(testing.allocator, {}, anyBytes, .{ .seed = 0x66757a7a, .cases = 3000 });
}
