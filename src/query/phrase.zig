//! A phrase's frequency in one document, from its terms' positions there.
//!
//! A match starts at a position `x` of the first term and takes, for each
//! next term, a position at least the phrase's distance (in the query)
//! past the one before; its `extra` is how much longer it is than the
//! phrase. A start matches when its shortest match's extra is at most the
//! slop, and adds `1 / (1 + extra)` to the frequency, so an exact phrase
//! counts its occurrences and a looser one counts less the looser it is.
//! Starts are taken rising, each distinct position once, and the sum is
//! an `f32` in that order.
//!
//! The shortest match of a start takes, term by term, the first position
//! far enough past the one before: no other choice ends sooner. A later
//! start's first choices are never before an earlier start's, so each
//! term's positions are walked once, forward.
//!
//! This file is internal. `probe.zig` is the package.
const aegis = @import("aegis");

/// The phrase's frequency: `lists` holds each term's positions in the
/// document, rising, and `offsets` each term's position in the query,
/// rising strictly. 0 when no start matches.
pub fn frequency(lists: []const []const u32, offsets: []const u32, slop: u32, cursors: []usize) f32 {
    aegis.assert.invariant(lists.len == offsets.len and lists.len == cursors.len and lists.len > 0, "a position list, an offset and a cursor per term");
    @memset(cursors, 0);
    const span: u64 = offsets[offsets.len - 1] - offsets[0];
    var freq: f32 = 0;
    var before: ?u32 = null;
    starts: for (lists[0]) |x| {
        if (before == x) continue;
        before = x;
        var at: u64 = x;
        for (lists[1..], offsets[1..], offsets[0 .. offsets.len - 1], cursors[1..]) |list, offset, previous, *cursor| {
            const need = at + (offset - previous);
            while (cursor.* < list.len and list[cursor.*] < need) cursor.* += 1;
            // No later start finds a position here either.
            if (cursor.* == list.len) break :starts;
            at = list[cursor.*];
        }
        const extra = at - x - span;
        if (extra > slop) continue;
        freq += 1 / @as(f32, @floatFromInt(1 + extra));
    }
    return freq;
}
