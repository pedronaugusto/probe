//! A merge: several segments' live documents written as one segment, and
//! the policy that chooses which.
//!
//! The documents keep their order, the sources' in turn, each source's by
//! doc, so the documents of an id keep theirs. The merged segment is
//! streamed through the segment writer (`files.Stream`) as it is made:
//! each field's terms are walked across the sources in byte order, each
//! term's entry read whole from every source that holds it, its postings
//! and positions renumbered, a deleted document's dropped, and written;
//! then each source's stored blocks in order, a live document's values
//! written again. The term dictionary, lengths, columns and ids are built
//! in memory meanwhile and written after. A merge holds the largest term's
//! entry and what it builds, never the merged segment.
//!
//! Each source is read once where it can: its term entries and its stored
//! blocks are read whole and in their order, so the CRC-32C of its postings
//! and store sections is taken from those reads and checked against its
//! table (the sections read whole when it was opened were checked then).
//! A source whose bytes are not what its table says, or whose entries do
//! not lie end to end, is `error.Corrupt`, the `Diagnostic` naming the
//! segment and the section. The merge checks for cancelation every MiB it
//! writes.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const Schema = @import("Schema.zig");
const encoding = @import("encoding.zig");
const bitmap = encoding.bitmap;
const fst = encoding.fst;
const segment = @import("segment.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const files = segment.files;
const terms = segment.terms;
const postings = segment.postings;
const positions = segment.positions;
const store = segment.store;
const write = segment.write;
const read = segment.read;
const block_len = encoding.bitpack.block_len;

pub const Error = error{ Corrupt, ReadFailed, WriteFailed, Canceled, OutOfMemory };

/// Which source and section a refused merge read.
pub const Diagnostic = struct {
    segment: u64 = 0,
    section: files.Section = .postings,
};

/// A segment to merge.
pub const Input = struct {
    number: u64,
    segment: *const read.Segment,
    /// Its deleted documents, which the merge drops.
    deleted: ?*const bitmap.Bitmap,
    /// Its table, whose CRC-32Cs the merge's reads are checked against; none
    /// for a segment held in memory, checked whole when it was built.
    table: ?files.Table,

    fn isDeleted(in: Input, doc: u32) bool {
        return if (in.deleted) |d| d.has(doc) else false;
    }
};

/// The writer checks for cancelation once this many bytes are written.
const cancel_every = 1 << 20;

/// What the merge holds while it runs.
const Merge = struct {
    gpa: Allocator,
    io: Io,
    schema: []const Schema.Field,
    /// The longest term the index holds.
    term_bytes: u16,
    inputs: []const Input,
    diagnostic: ?*Diagnostic,
    stream: *files.Stream,
    /// Each input's documents renumbered: `gone` for a deleted one.
    maps: [][]u32,
    /// Per input: where its next term entry must start, and the CRC-32C of
    /// its entries read so far.
    expected: []u64,
    crcs: []u32,
    /// The merged lengths per text field, by place.
    lengths: [][]u32,
    checked_at: u64 = 0,

    const gone = std.math.maxInt(u32);

    fn refuse(m: *Merge, input: usize, section: files.Section) error{Corrupt} {
        if (m.diagnostic) |d| d.* = .{ .segment = m.inputs[input].number, .section = section };
        return error.Corrupt;
    }

    fn checkCancel(m: *Merge) error{Canceled}!void {
        if (m.stream.written - m.checked_at < cancel_every) return;
        m.checked_at = m.stream.written;
        try m.io.checkCancel();
    }
};

/// Merges `inputs`, segments of documents of `schema` whose terms are at
/// most `term_bytes` long, into segment `number`'s file streamed into
/// `out`: its live documents' count.
pub fn merge(gpa: Allocator, io: Io, schema: []const Schema.Field, term_bytes: u16, inputs: []const Input, out: *Io.Writer, number: u64, diagnostic: ?*Diagnostic) Error!u32 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var stream = files.Stream.begin(out, number) catch return error.WriteFailed;
    var m: Merge = .{
        .gpa = gpa,
        .io = io,
        .schema = schema,
        .term_bytes = term_bytes,
        .inputs = inputs,
        .diagnostic = diagnostic,
        .stream = &stream,
        .maps = try a.alloc([]u32, inputs.len),
        .expected = try a.alloc(u64, inputs.len),
        .crcs = try a.alloc(u32, inputs.len),
        .lengths = try a.alloc([]u32, schema.len),
    };
    @memset(m.expected, 0);
    @memset(m.crcs, 0);

    // Renumber, and gather what is built in memory.
    var docs: u32 = 0;
    for (inputs, m.maps) |in, *map| {
        map.* = try a.alloc(u32, in.segment.docs);
        for (map.*, 0..) |*to, d| {
            to.* = if (in.isDeleted(@intCast(d))) Merge.gone else blk: {
                docs += 1;
                break :blk docs - 1;
            };
        }
    }
    const ids = try a.alloc(u64, docs);
    const totals = try a.alloc(u64, schema.len);
    const cols = try a.alloc([]u64, schema.len);
    for (schema, m.lengths, totals, cols) |f, *l, *t, *c| {
        l.* = if (f.kind == .text) try a.alloc(u32, docs) else &.{};
        c.* = if (f.kind == .numeric) try a.alloc(u64, docs) else &.{};
        t.* = 0;
    }
    for (inputs, m.maps, 0..) |in, map, i| {
        var cursors = try a.alloc(?segment.columns.Cursor, schema.len);
        for (cursors, in.segment.columns) |*cur, col| cur.* = if (col) |c| .init(c) else null;
        for (map, 0..) |to, d| {
            if (to == Merge.gone) continue;
            const doc: u32 = @intCast(d);
            ids[to] = in.segment.idOf(doc);
            for (schema, 0..) |f, place| switch (f.kind) {
                .text => {
                    const l = in.segment.length(@intCast(place), doc);
                    m.lengths[place][to] = l;
                    totals[place] += l;
                },
                .numeric => cols[place][to] = cursors[place].?.get(doc) catch return m.refuse(i, .columns),
                .keyword => {},
            };
        }
    }

    // The postings, field by field, and the dictionary they lead to.
    var dictionary: std.ArrayList(u8) = .empty;
    defer dictionary.deinit(gpa);
    try mergeTerms(&m, &dictionary);
    for (inputs, 0..) |in, i| {
        const t = in.table orelse continue;
        const e = t.of(.postings);
        if (m.expected[i] != e.len or m.crcs[i] != e.crc) return m.refuse(i, .postings);
    }
    stream.end(.postings);

    try mergeStore(&m);
    stream.end(.store);

    var section: std.ArrayList(u8) = .empty;
    defer section.deinit(gpa);
    try put(&stream, dictionary.items);
    stream.end(.terms);
    try write.appendLengths(gpa, &section, schema, try constSlices(u32, a, m.lengths), totals);
    try put(&stream, section.items);
    stream.end(.lengths);
    section.clearRetainingCapacity();
    try write.appendColumns(gpa, &section, schema, try constSlices(u64, a, cols));
    try put(&stream, section.items);
    stream.end(.columns);
    section.clearRetainingCapacity();
    try write.appendIds(gpa, &section, ids);
    try put(&stream, section.items);
    stream.end(.ids);
    stream.finish() catch return error.WriteFailed;
    return docs;
}

/// `slices` as read-only, copied on `a`.
fn constSlices(comptime T: type, a: Allocator, slices: []const []T) Allocator.Error![]const []const T {
    const out = try a.alloc([]const T, slices.len);
    for (out, slices) |*o, s| o.* = s;
    return out;
}

fn put(stream: *files.Stream, bytes: []const u8) error{WriteFailed}!void {
    stream.write(bytes) catch return error.WriteFailed;
}

/// A walk of one input's terms of one field.
const Cursor = struct {
    input: usize,
    field: terms.Field,
    walk: fst.Fst.Walk,
    current: ?fst.Fst.Walk.Entry,
    /// Where the input's entries after this field's start: the next field's
    /// first, or the section's end.
    after: u64,

    fn advance(c: *Cursor, m: *Merge) error{Corrupt}!void {
        c.current = c.walk.next() catch return m.refuse(c.input, .terms);
    }

    /// Where the entry of `ordinal` ends: where the next one starts.
    fn endOf(c: *const Cursor, m: *Merge, ordinal: u64) error{Corrupt}!u64 {
        if (ordinal + 1 < c.field.terms) return (c.field.address(ordinal + 1) catch return m.refuse(c.input, .terms)).postings;
        return c.after;
    }
};

fn mergeTerms(m: *Merge, dictionary: *std.ArrayList(u8)) Error!void {
    const gpa = m.gpa;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var indexed: u32 = 0;
    var places: std.ArrayList(u32) = .empty;
    for (m.schema, 0..) |_, p| {
        const place: u32 = @intCast(p);
        for (m.inputs, 0..) |in, i| {
            if ((in.segment.dictionary.field(place) catch return m.refuse(i, .terms)) != null) break;
        } else continue;
        try places.append(a, place);
        indexed += 1;
    }
    // Where each input's entries of each field start, to end the field
    // before it.
    const firsts = try a.alloc([]?u64, m.inputs.len);
    for (m.inputs, firsts, 0..) |in, *f, i| {
        f.* = try a.alloc(?u64, m.schema.len);
        for (f.*, 0..) |*first, p| {
            const field = (in.segment.dictionary.field(@intCast(p)) catch return m.refuse(i, .terms)) orelse {
                first.* = null;
                continue;
            };
            first.* = if (field.terms == 0) null else (field.address(0) catch return m.refuse(i, .terms)).postings;
        }
    }
    try terms.begin(gpa, dictionary, indexed);
    var t: TermState = .{};
    defer t.deinit(gpa);
    for (places.items) |place| {
        var cursors: std.ArrayList(Cursor) = .empty;
        for (m.inputs, 0..) |in, i| {
            const field = (in.segment.dictionary.field(place) catch return m.refuse(i, .terms)) orelse continue;
            var after: u64 = in.segment.postings.len();
            for (firsts[i][place + 1 ..]) |first| if (first) |f| {
                after = f;
                break;
            };
            const key = try a.alloc(u8, m.term_bytes);
            const frames = try a.alloc(fst.Fst.Frame, @as(usize, m.term_bytes) + 1);
            var c: Cursor = .{ .input = i, .field = field, .walk = field.keys.walk("", key, frames) catch return m.refuse(i, .terms), .current = null, .after = after };
            try c.advance(m);
            try cursors.append(a, c);
        }
        var writer: terms.FieldWriter = .init(gpa);
        defer writer.deinit();
        var key: std.ArrayList(u8) = .empty;
        defer key.deinit(gpa);
        while (true) {
            var least: ?[]const u8 = null;
            for (cursors.items) |c| if (c.current) |e| {
                if (least == null or std.mem.order(u8, e.key, least.?) == .lt) least = e.key;
            };
            key.clearRetainingCapacity();
            try key.appendSlice(gpa, least orelse break);
            t.clear();
            for (cursors.items) |*c| {
                const e = c.current orelse continue;
                if (!std.mem.eql(u8, e.key, key.items)) continue;
                try readEntry(m, &t, c, place, e.value);
                try c.advance(m);
            }
            if (t.list.items.len == 0) continue;
            const address = try t.emit(m, place);
            writer.add(key.items, address) catch |err| return write.rising(err);
            try m.checkCancel();
        }
        try writer.finish(place, dictionary);
    }
}

/// One merged term's postings and tokens being gathered.
const TermState = struct {
    /// The renumbered postings, and each one's tokens: where they start in
    /// `tokens`.
    list: std.ArrayList(postings.Posting) = .empty,
    starts: std.ArrayList(usize) = .empty,
    tokens: std.ArrayList(positions.Token) = .empty,
    /// An input's entry as read, and its postings before renumbering.
    entry: std.ArrayList(u8) = .empty,
    read: std.ArrayList(postings.Posting) = .empty,
    out: std.ArrayList(u8) = .empty,
    slices: std.ArrayList([]const positions.Token) = .empty,

    fn clear(t: *TermState) void {
        t.list.clearRetainingCapacity();
        t.starts.clearRetainingCapacity();
        t.tokens.clearRetainingCapacity();
    }

    fn deinit(t: *TermState, gpa: Allocator) void {
        t.list.deinit(gpa);
        t.starts.deinit(gpa);
        t.tokens.deinit(gpa);
        t.entry.deinit(gpa);
        t.read.deinit(gpa);
        t.out.deinit(gpa);
        t.slices.deinit(gpa);
    }

    /// Writes the term's entry; its address.
    fn emit(t: *TermState, m: *Merge, place: u32) Error!terms.Address {
        const gpa = m.gpa;
        const field = m.schema[place];
        t.slices.clearRetainingCapacity();
        if (field.positions) {
            for (t.starts.items, 0..) |start, i| {
                const end = if (i + 1 < t.starts.items.len) t.starts.items[i + 1] else t.tokens.items.len;
                try t.slices.append(gpa, t.tokens.items[start..end]);
            }
        }
        t.out.clearRetainingCapacity();
        const lengths: ?[]const u32 = if (field.kind == .text) m.lengths[place] else null;
        const address = try write.appendEntry(gpa, &t.out, m.stream.at(), field, t.list.items, lengths, t.slices.items);
        try put(m.stream, t.out.items);
        return address;
    }
};

/// Reads input `c.input`'s entry of the term of `ordinal` in the field at
/// `place` whole, in order, and gathers its live postings renumbered.
fn readEntry(m: *Merge, t: *TermState, c: *const Cursor, place: u32, ordinal: u64) Error!void {
    const gpa = m.gpa;
    const i = c.input;
    const in = m.inputs[i];
    const field = m.schema[place];
    const address = c.field.address(ordinal) catch return m.refuse(i, .terms);
    const end = try c.endOf(m, ordinal);
    if (address.postings != m.expected[i] or end < address.postings or end > in.segment.postings.len()) return m.refuse(i, .postings);
    try t.entry.resize(gpa, @intCast(end - address.postings));
    try in.segment.postings.read(m.io, address.postings, t.entry.items);
    m.crcs[i] = files.crc32c(m.crcs[i], t.entry.items);
    m.expected[i] = end;
    const bytes: segment.source.Source = .{ .memory = t.entry.items };
    var p = postings.Reader.init(bytes, m.io, 0, in.segment.docs) catch return m.refuse(i, .postings);
    t.read.clearRetainingCapacity();
    while (p.next() catch return m.refuse(i, .postings)) |posting| try t.read.append(gpa, posting);
    if ((address.positions != terms.no_positions) != field.positions) return m.refuse(i, .postings);
    var pos: ?positions.Reader = if (!field.positions) null else blk: {
        if (address.positions < address.postings or address.positions > end) return m.refuse(i, .postings);
        break :blk positions.Reader.init(bytes, m.io, address.positions - address.postings, p.docFreq(), field.offsets) catch return m.refuse(i, .postings);
    };
    var block_start: usize = 0;
    while (block_start < t.read.items.len) : (block_start += block_len) {
        const block = t.read.items[block_start..@min(block_start + block_len, t.read.items.len)];
        if (pos) |*r| {
            var sum: u64 = 0;
            for (block) |b| sum += b.freq;
            r.enter(@intCast(block_start / block_len), sum) catch return m.refuse(i, .postings);
        }
        for (block) |b| {
            const to = m.maps[i][b.doc];
            if (pos) |*r| r.document(b.freq) catch return m.refuse(i, .postings);
            if (to == Merge.gone) {
                if (pos) |*r| r.skip() catch return m.refuse(i, .postings);
                continue;
            }
            try t.list.append(gpa, .{ .doc = to, .freq = b.freq });
            try t.starts.append(gpa, t.tokens.items.len);
            if (pos) |*r| for (0..b.freq) |_| {
                const token = (r.next() catch return m.refuse(i, .postings)) orelse return m.refuse(i, .postings);
                try t.tokens.append(gpa, token);
            };
        }
    }
}

/// Each input's stored blocks in order, a live document's values written
/// again.
fn mergeStore(m: *Merge) Error!void {
    const gpa = m.gpa;
    var w: store.Writer = try .init(gpa);
    defer w.deinit();
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(gpa);
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    var slots: usize = 0;
    for (m.schema) |f| slots += @intFromBool(f.stored);
    const values = try gpa.alloc(store.Value, slots);
    defer gpa.free(values);
    for (m.inputs, m.maps, 0..) |in, map, i| {
        const st = in.segment.stored;
        var crc: u32 = 0;
        for (0..st.blocks) |b| {
            const block = st.readBlock(m.io, gpa, @intCast(b), &compressed, &raw) catch |err| return switch (err) {
                error.Corrupt => m.refuse(i, .store),
                else => |e| e,
            };
            crc = files.crc32c(crc, compressed.items);
            var at: usize = 0;
            for (block.first..block.end) |d| {
                st.values(raw.items, &at, values) catch return m.refuse(i, .store);
                if (map[d] == Merge.gone) continue;
                try w.add(values);
                try put(m.stream, w.ready());
                w.take();
            }
            if (at != raw.items.len) return m.refuse(i, .store);
            try m.checkCancel();
        }
        if (in.table) |t| {
            if (files.crc32c(crc, st.table) != t.of(.store).crc) return m.refuse(i, .store);
        }
    }
    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(gpa);
    try w.finish(&tail);
    try put(m.stream, tail.items);
}

/// Which segments to merge: Lucene's tiered merge policy. A segment's size
/// is its file's bytes in proportion to its live documents; one smaller
/// than `floor_bytes` counts as that much. The index may hold
/// `segments_per_tier` segments of each tier, the first tier's size the
/// smallest segment's (at least the floor), each next tier's that times the
/// merge factor (`max_merge_at_once` or `segments_per_tier`, the smaller),
/// up to `max_merged_bytes`. A segment past half that whose deleted share
/// is within `deletes_pct_allowed` is left alone: it counts in no budget.
///
/// A merge is due when the other segments are more than the tiers allow,
/// or their deleted documents more than `deletes_pct_allowed` of every
/// segment's documents. Then each run of segments, largest first, is a
/// candidate: from each segment on, the next ones are taken while their
/// sum stays within `max_merged_bytes`, one that would pass it skipped (so
/// the segments of a merge need not be adjacent), up to the merge factor.
/// A candidate of one segment is a rewrite, made only to reclaim its
/// deletes. Each candidate is scored, the lowest winning:
///
///     skew       its largest segment's floored size over the floored sum,
///                or 1 / factor when a segment was skipped as too large
///     size       the merged size to the power 0.05, so smaller merges win
///                a tie of skew
///     reclaim    (merged size / size before) squared, so a merge that
///                drops deleted documents wins
///
///     score = skew * size * reclaim
pub const Policy = struct {
    /// The largest a merge may make a segment, in live bytes.
    max_merged_bytes: u64 = 5 * 1024 * 1024 * 1024,
    segments_per_tier: u8 = 10,
    max_merge_at_once: u8 = 10,
    /// A segment smaller counts as this size.
    floor_bytes: u64 = 2 * 1024 * 1024,
    /// The share of documents that may be deleted, in percent, 5 to 50.
    deletes_pct_allowed: u8 = 20,

    /// A segment as the policy sees it.
    pub const Size = struct { bytes: u64, docs: u32, deleted: u32 };

    /// The budget the policy keeps `sizes` within: the segments the tiers
    /// allow, and the deleted documents.
    pub const Budget = struct { segments: u64, deleted: u64 };

    fn check(p: Policy) void {
        aegis.assert.invariant(p.segments_per_tier >= 2 and p.max_merge_at_once >= 2, "a merge takes two segments at least");
        aegis.assert.invariant(p.deletes_pct_allowed >= 5 and p.deletes_pct_allowed <= 50, "deletes allowed between 5 and 50 percent");
        aegis.assert.invariant(p.floor_bytes > 0 and p.max_merged_bytes >= p.floor_bytes, "a floor under the cap");
    }

    fn factor(p: Policy) u64 {
        return @min(p.max_merge_at_once, p.segments_per_tier);
    }

    /// `s`'s live bytes: its bytes in proportion to its live documents.
    pub fn liveBytes(s: Size) u64 {
        if (s.docs == 0) return 0;
        return @intCast(@as(u128, s.bytes) * (s.docs - s.deleted) / s.docs);
    }

    fn floored(p: Policy, bytes: u64) u64 {
        return @max(bytes, p.floor_bytes);
    }

    /// Whether `s` is left alone: past half the cap, its deletes within the
    /// allowance.
    fn tooLarge(p: Policy, s: Size) bool {
        return liveBytes(s) > p.max_merged_bytes / 2 and @as(u64, s.deleted) * 100 <= @as(u64, s.docs) * p.deletes_pct_allowed;
    }

    /// The budget for `sizes`: what `choose` keeps them within.
    pub fn budget(p: Policy, sizes: []const Size) Budget {
        p.check();
        var total: u64 = 0;
        var smallest: u64 = std.math.maxInt(u64);
        var docs: u64 = 0;
        for (sizes) |s| {
            docs += s.docs;
            if (p.tooLarge(s)) continue;
            total += liveBytes(s);
            smallest = @min(smallest, liveBytes(s));
        }
        var level = @max(smallest, p.floor_bytes);
        var left = total;
        var allowed: u64 = 0;
        if (smallest != std.math.maxInt(u64)) while (true) {
            const at_level = (left + level - 1) / level;
            if (left / level < p.segments_per_tier or level == p.max_merged_bytes) {
                allowed += at_level;
                break;
            }
            allowed += p.segments_per_tier;
            left -= @as(u64, p.segments_per_tier) * level;
            level = @min(p.max_merged_bytes, level * p.factor());
        };
        return .{ .segments = @max(allowed, p.segments_per_tier), .deleted = docs * p.deletes_pct_allowed / 100 };
    }

    /// The places in `sizes` of the segments to merge, rising, in `out`
    /// (as long as `sizes`); none when the index is within its budget.
    pub fn choose(p: Policy, sizes: []const Size, out: []usize) []usize {
        p.check();
        aegis.assert.invariant(out.len >= sizes.len, "room for every segment");
        const b = p.budget(sizes);
        // The segments in the budget, largest first.
        var n: usize = 0;
        var deleted: u64 = 0;
        for (sizes, 0..) |s, i| {
            if (p.tooLarge(s)) continue;
            out[n] = i;
            n += 1;
            deleted += s.deleted;
        }
        const eligible = out[0..n];
        if (eligible.len <= b.segments and deleted <= b.deleted) return out[0..0];
        std.mem.sort(usize, eligible, sizes, struct {
            fn moreThan(s: []const Size, x: usize, y: usize) bool {
                const a = liveBytes(s[x]);
                const c = liveBytes(s[y]);
                return a > c or (a == c and x < y);
            }
        }.moreThan);
        var best: Candidate = .{};
        var best_score: ?f64 = null;
        for (0..eligible.len) |start| {
            const c = p.candidate(sizes, eligible, start);
            // Past a full merge, shorter ones from smaller segments on
            // only score worse.
            if (best_score != null and !c.too_large and c.count < p.factor()) break;
            // A candidate takes its first segment, and one alone is a
            // rewrite to reclaim deletes: a segment without them under half
            // the cap has a smaller one after it that fits, or is the last,
            // where the merge found from an earlier start ends the walk; one
            // over half is left alone. Probe has no forced merge, the one
            // path that would rewrite a segment for nothing.
            aegis.assert.invariant(c.count > 1 or (c.count == 1 and sizes[c.members[0]].deleted > 0), "a segment written again alone has deletes to reclaim");
            const score = p.scoreOf(sizes, &c);
            if (best_score == null or score < best_score.?) {
                best = c;
                best_score = score;
            }
        }
        if (best_score == null) return out[0..0];
        const chosen = out[0..best.count];
        @memcpy(chosen, best.members[0..best.count]);
        std.mem.sort(usize, chosen, {}, std.sort.asc(usize));
        return chosen;
    }

    /// A candidate: the places of the segments it takes, largest first,
    /// their live bytes, and whether one was skipped as too large.
    const Candidate = struct {
        members: [std.math.maxInt(u8)]usize = undefined,
        count: usize = 0,
        too_large: bool = false,
        bytes: u64 = 0,

        fn take(c: *Candidate, place: usize, bytes: u64) void {
            c.members[c.count] = place;
            c.count += 1;
            c.bytes += bytes;
        }
    };

    fn candidate(p: Policy, sizes: []const Size, eligible: []const usize, start: usize) Candidate {
        var c: Candidate = .{};
        var at = start;
        while (at < eligible.len and c.count < p.factor() and c.bytes < p.max_merged_bytes) : (at += 1) {
            const bytes = liveBytes(sizes[eligible[at]]);
            if (c.bytes + bytes > p.max_merged_bytes) {
                c.too_large = true;
                // A segment that cannot be merged with any is a rewrite.
                if (c.count == 0) c.take(eligible[at], bytes);
                continue;
            }
            c.take(eligible[at], bytes);
        }
        return c;
    }

    fn scoreOf(p: Policy, sizes: []const Size, c: *const Candidate) f64 {
        var before: u64 = 0;
        var after_floored: u64 = 0;
        for (c.members[0..c.count]) |place| {
            before += sizes[place].bytes;
            after_floored += p.floored(liveBytes(sizes[place]));
        }
        const skew: f64 = if (c.too_large)
            1.0 / @as(f64, @floatFromInt(p.factor()))
        else
            @as(f64, @floatFromInt(p.floored(liveBytes(sizes[c.members[0]])))) / @as(f64, @floatFromInt(after_floored));
        const size = std.math.pow(f64, @floatFromInt(@max(c.bytes, 1)), 0.05);
        const kept = if (before == 0) 1.0 else @as(f64, @floatFromInt(c.bytes)) / @as(f64, @floatFromInt(before));
        return skew * size * kept * kept;
    }
};
