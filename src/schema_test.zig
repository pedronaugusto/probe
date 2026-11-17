//! A document type's declaration read as its schema, and numeric values as
//! their columns' integers, in order.
const std = @import("std");
const aegis = @import("aegis");
const probe = @import("probe.zig");

const testing = std.testing;
const Schema = probe.Schema;

const Entry = struct {
    seq: aegis.id.Id(Entry, u64),
    at: i64,
    level: []const u8,
    message: []const u8,
    note: []const u8 = "",

    pub const probe = .{
        .id = .seq,
        .fields = .{
            .at = .{ .numeric = .{} },
            .level = .{ .keyword = .{ .stored = true } },
            .message = .{ .text = .{ .positions = true, .offsets = true, .analysis = .words_and_identifiers } },
        },
    };
};

test "a document type's declaration is its schema, its fields in the order declared" {
    const S = Schema.Of(Entry);
    try testing.expectEqualStrings("seq", S.id_field);
    try testing.expectEqual(@as(usize, 3), S.all.len);
    try testing.expectEqualStrings("at", S.all[0].name);
    try testing.expectEqual(Schema.Kind.numeric, S.all[0].kind);
    try testing.expectEqual(Schema.Kind.keyword, S.all[1].kind);
    try testing.expect(S.all[1].stored);
    const message = S.all[S.indexOf("message")];
    try testing.expectEqual(Schema.Kind.text, message.kind);
    try testing.expect(message.positions and message.offsets);
    try testing.expectEqual(Schema.Analysis.words_and_identifiers, message.analysis);
    try testing.expect(!message.stored);
}

test "numeric values keep their order as their columns' integers" {
    const values = [_]i64{ std.math.minInt(i64), -5, -1, 0, 1, 7, std.math.maxInt(i64) };
    for (values[0 .. values.len - 1], values[1..]) |a, b| {
        try testing.expect(Schema.columnValue(a) < Schema.columnValue(b));
    }
    try testing.expectEqual(@as(u64, 42), Schema.columnValue(@as(u64, 42)));
    const Count = aegis.units.Count(enum { thing }, u64);
    try testing.expectEqual(@as(u64, 9), Schema.columnValue(Count.fromRaw(9)));
    try testing.expectEqual(u64, Schema.ColumnRepr(aegis.id.Id(Entry, u64)));
    try testing.expectEqual(void, Schema.ColumnRepr(u32));
}
