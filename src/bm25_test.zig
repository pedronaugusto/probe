//! BM25's logarithm, made of IEEE basic operations so a score's bits are the
//! same on every target: within `max_ulps` of the platform's `log` over
//! every argument an idf takes, and its rounded idfs and averages equal to
//! constants fixed here, which every CI target checks.
const std = @import("std");
const shakedown = @import("shakedown");
const bm25 = @import("bm25.zig");

const testing = std.testing;
const gen = shakedown.gen;

/// The most units in the last place `ln` is from the platform's `log`.
const max_ulps = 2;

fn ulpsApart(got: f64, want: f64) f64 {
    const spacing = std.math.nextAfter(f64, @abs(want), std.math.inf(f64)) - @abs(want);
    return @abs(got - want) / spacing;
}

fn nearLog(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    // An idf's argument, 1 + (N - df + 0.5) / (df + 0.5), for a snapshot
    // of up to 2^63 documents: from just above 1 to 2^64.
    const x: f64 = if (gen.boolean(s)) idf: {
        const docs = gen.intRange(s, u64, 0, @as(u64, 1) << @intCast(gen.intRange(s, u6, 0, 63)));
        const df: f64 = @floatFromInt(gen.intRange(s, u64, 0, docs));
        const n: f64 = @floatFromInt(docs);
        break :idf 1 + (n - df + 0.5) / (df + 0.5);
    } else any: {
        const m = 1 + @as(f64, @floatFromInt(gen.int(s, u52))) / 0x1p52;
        break :any std.math.ldexp(m, gen.intRange(s, i32, 0, 63));
    };
    const want = @log(x);
    if (ulpsApart(bm25.ln(x), want) > max_ulps) std.debug.print("x {e} ({x}) ln {e} log {e} ulps {d}\n", .{ x, @as(u64, @bitCast(x)), bm25.ln(x), want, ulpsApart(bm25.ln(x), want) });
    try testing.expect(ulpsApart(bm25.ln(x), want) <= max_ulps);
}

test "ln is within two units in the last place of the platform's log over every argument an idf takes" {
    try shakedown.check(testing.allocator, {}, nearLog, .{ .seed = 0x6c6e_6c6e, .cases = 100_000 });
}

test "ln at the edges of its range: 1, just above it, a power of two, and 2^64" {
    try testing.expectEqual(@as(f64, 0), bm25.ln(1));
    for ([_]f64{ std.math.nextAfter(f64, 1, 2), 1 + 0x1p-30, 2, std.math.sqrt2, 0x1p64 }) |x| {
        try testing.expect(ulpsApart(bm25.ln(x), @log(x)) <= max_ulps);
    }
}

test "idfs and averages rounded to f32 are these bits on every target" {
    const cases = [_]struct { docs: u64, df: u64, bits: u32 }{
        .{ .docs = 1, .df = 1, .bits = 0x3e934b11 },
        .{ .docs = 10, .df = 1, .bits = 0x3fff07f4 },
        .{ .docs = 1000, .df = 7, .bits = 0x409c9a6f },
        .{ .docs = 1_000_000, .df = 999_999, .bits = 0x35c95398 },
        .{ .docs = 8_841_823, .df = 12_345, .bits = 0x40d25ddb },
        .{ .docs = 1 << 40, .df = 3, .bits = 0x41d3c8f5 },
    };
    for (cases) |c| try testing.expectEqual(c.bits, @as(u32, @bitCast(bm25.idf(c.docs, c.df))));
    const averages = [_]struct { docs: u64, total: u64, bits: u32 }{
        .{ .docs = 3, .total = 10, .bits = 0x40555555 },
        .{ .docs = 8_841_823, .total = 487_345_123, .bits = 0x425c7902 },
    };
    for (averages) |a| try testing.expectEqual(a.bits, @as(u32, @bitCast(bm25.average(a.docs, a.total))));
}
