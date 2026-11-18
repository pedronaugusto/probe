//! A finite state transducer from byte strings to `u64`s: a segment's term
//! dictionary (each term to its postings' address and its document
//! frequency, packed) and its external ids. Built from keys in strictly
//! rising order (Daciuk, Mihov, Watson and Watson, "Incremental construction
//! of minimal acyclic finite-state automata", 2000), each node written once
//! and every node equal to one already written shared, so keys with a common
//! suffix share their tails as keys with a common prefix share their heads.
//! A key's output is the sum of the outputs on its path and its last node's
//! final output, each transition holding what every key through it shares.
//!
//! The bytes: the nodes, each written after every node it leads to, then the
//! root's address and the number of keys, eight bytes each, little endian. A
//! node is a flags byte (bit 0: a key ends here), its final output when it
//! has one, its transitions' count, their labels in strictly rising order,
//! then each transition's output and how far back its target lies, all
//! counts and outputs as LEB128 varints. A target lies strictly before its
//! node, so every walk over any bytes ends: what is read is checked as it is
//! read, and bytes that break a rule are `error.Corrupt`.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const varint = @import("varint.zig");

/// Bytes that are not an FST, or a walk past what they can say.
pub const Error = error{Corrupt};

const footer_bytes = 16;
const final_flag: u8 = 1;
/// A node has at most one transition per byte.
const max_transitions = 256;

/// Builds an FST from keys added in strictly rising order.
pub const Builder = struct {
    gpa: Allocator,
    /// The nodes written so far.
    bytes: std.ArrayList(u8) = .empty,
    /// Every node written, by its contents with its targets' addresses, to
    /// the address it was written at.
    registry: std.StringHashMapUnmanaged(u64) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    /// The nodes along the last key, the root first, not yet written.
    unfinished: std.ArrayList(Unfinished) = .empty,
    last: std.ArrayList(u8) = .empty,
    keys: u64 = 0,
    /// Distinct nodes written.
    nodes: u64 = 0,

    const Transition = struct { label: u8, out: u64, target: u64 = 0 };

    const Unfinished = struct {
        final: bool = false,
        final_out: u64 = 0,
        transitions: std.ArrayList(Transition) = .empty,
    };

    pub const AddError = Allocator.Error || error{NotRising};

    pub fn init(gpa: Allocator) Builder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(b: *Builder) void {
        var it = b.registry.keyIterator();
        while (it.next()) |key| b.gpa.free(key.*);
        b.registry.deinit(b.gpa);
        for (b.unfinished.items) |*u| u.transitions.deinit(b.gpa);
        b.unfinished.deinit(b.gpa);
        b.bytes.deinit(b.gpa);
        b.scratch.deinit(b.gpa);
        b.last.deinit(b.gpa);
        b.* = undefined;
    }

    /// Adds `key`, which comes after every key added before it, with
    /// `value`; `error.NotRising` adds nothing, and `error.OutOfMemory`
    /// leaves the builder spent, for `deinit` alone.
    pub fn add(b: *Builder, key: []const u8, value: u64) AddError!void {
        if (b.unfinished.items.len == 0) try b.unfinished.append(b.gpa, .{});
        if (b.keys != 0 and std.mem.order(u8, b.last.items, key) != .lt) return error.NotRising;
        const prefix = if (b.keys == 0) 0 else std.mem.findDiff(u8, b.last.items, key) orelse key.len;
        try b.freeze(prefix);
        // The shared path keeps what this key has in common with the ones
        // before it; the rest is pushed one node down.
        var out = value;
        for (0..prefix) |i| {
            const t = &b.unfinished.items[i].transitions.items[b.unfinished.items[i].transitions.items.len - 1];
            const common = @min(t.out, out);
            const extra = t.out - common;
            t.out = common;
            out -= common;
            if (extra != 0) {
                const child = &b.unfinished.items[i + 1];
                for (child.transitions.items) |*ct| ct.out += extra;
                if (child.final) child.final_out += extra;
            }
        }
        if (key.len == prefix) {
            // Only the first key can end where it begins: the empty key.
            const node = &b.unfinished.items[prefix];
            node.final = true;
            node.final_out = out;
        } else {
            try b.unfinished.ensureUnusedCapacity(b.gpa, key.len - prefix);
            for (key[prefix..], prefix..) |label, j| {
                try b.unfinished.items[j].transitions.append(b.gpa, .{ .label = label, .out = if (j == prefix) out else 0 });
                b.unfinished.appendAssumeCapacity(.{});
            }
            b.unfinished.items[key.len].final = true;
        }
        b.last.clearRetainingCapacity();
        try b.last.appendSlice(b.gpa, key);
        b.keys += 1;
    }

    /// The FST of the keys added, into `out` (cleared first). The builder is
    /// spent.
    pub fn finish(b: *Builder, out: *std.ArrayList(u8)) Allocator.Error!void {
        if (b.unfinished.items.len == 0) try b.unfinished.append(b.gpa, .{});
        try b.freeze(0);
        const root = try b.compile(&b.unfinished.items[0]);
        var footer: [footer_bytes]u8 = undefined;
        std.mem.writeInt(u64, footer[0..8], root, .little);
        std.mem.writeInt(u64, footer[8..16], b.keys, .little);
        try b.bytes.appendSlice(b.gpa, &footer);
        out.clearRetainingCapacity();
        try out.appendSlice(b.gpa, b.bytes.items);
    }

    /// Writes the unfinished nodes deeper than `depth`, the deepest first,
    /// each one's address given to its parent's last transition.
    fn freeze(b: *Builder, depth: usize) Allocator.Error!void {
        while (b.unfinished.items.len > depth + 1) {
            var node = b.unfinished.pop().?;
            defer node.transitions.deinit(b.gpa);
            const address = try b.compile(&node);
            const parent = &b.unfinished.items[b.unfinished.items.len - 1];
            parent.transitions.items[parent.transitions.items.len - 1].target = address;
        }
    }

    /// The address of a node equal to `node`, written now if none was.
    fn compile(b: *Builder, node: *const Unfinished) Allocator.Error!u64 {
        b.scratch.clearRetainingCapacity();
        try b.scratch.append(b.gpa, @intFromBool(node.final));
        try varint.append(b.gpa, &b.scratch, node.final_out);
        for (node.transitions.items) |t| {
            try b.scratch.append(b.gpa, t.label);
            try varint.append(b.gpa, &b.scratch, t.out);
            try varint.append(b.gpa, &b.scratch, t.target);
        }
        const entry = try b.registry.getOrPut(b.gpa, b.scratch.items);
        if (entry.found_existing) return entry.value_ptr.*;
        entry.key_ptr.* = b.gpa.dupe(u8, b.scratch.items) catch |err| {
            b.registry.removeByPtr(entry.key_ptr);
            return err;
        };
        const address: u64 = b.bytes.items.len;
        entry.value_ptr.* = address;
        try b.bytes.append(b.gpa, if (node.final) final_flag else 0);
        if (node.final) try varint.append(b.gpa, &b.bytes, node.final_out);
        try varint.append(b.gpa, &b.bytes, node.transitions.items.len);
        for (node.transitions.items) |t| try b.bytes.append(b.gpa, t.label);
        for (node.transitions.items) |t| {
            aegis.assert.invariant(t.target < address, "a node is written after every node it leads to");
            try varint.append(b.gpa, &b.bytes, t.out);
            try varint.append(b.gpa, &b.bytes, address - t.target);
        }
        b.nodes += 1;
        return address;
    }
};

/// An FST read from bytes, borrowing them.
pub const Fst = struct {
    /// The nodes, without the footer.
    nodes: []const u8,
    root: u64,
    keys: u64,

    /// The FST `bytes` hold, its footer checked; each node is checked as a
    /// walk reads it.
    pub fn parse(bytes: []const u8) Error!Fst {
        if (bytes.len < footer_bytes + 1) return error.Corrupt;
        const nodes = bytes[0 .. bytes.len - footer_bytes];
        const root = std.mem.readInt(u64, bytes[nodes.len..][0..8], .little);
        if (root >= nodes.len) return error.Corrupt;
        return .{ .nodes = nodes, .root = root, .keys = std.mem.readInt(u64, bytes[nodes.len + 8 ..][0..8], .little) };
    }

    /// The value of `key`, or null when the FST does not hold it.
    pub fn get(f: Fst, key: []const u8) Error!?u64 {
        var address = f.root;
        var out: u64 = 0;
        for (key) |label| {
            const node = try f.nodeAt(address);
            const i = std.mem.findScalar(u8, node.labels, label) orelse return null;
            var at = node.pairs;
            var t: Pair = undefined;
            for (0..i + 1) |_| t = try f.pairAt(&at, address);
            out = std.math.add(u64, out, t.out) catch return error.Corrupt;
            address = t.target;
        }
        const node = try f.nodeAt(address);
        if (!node.final) return null;
        return std.math.add(u64, out, node.final_out) catch error.Corrupt;
    }

    const Node = struct { final: bool, final_out: u64, labels: []const u8, pairs: usize };
    const Pair = struct { out: u64, target: u64 };

    fn nodeAt(f: Fst, address: u64) Error!Node {
        if (address >= f.nodes.len) return error.Corrupt;
        var at: usize = @intCast(address);
        const flags = f.nodes[at];
        at += 1;
        if (flags & ~final_flag != 0) return error.Corrupt;
        const final = flags & final_flag != 0;
        const final_out = if (final) try varint.read(f.nodes, &at) else 0;
        const count = try varint.read(f.nodes, &at);
        if (count > max_transitions or count > f.nodes.len - at) return error.Corrupt;
        const labels = f.nodes[at..][0..@intCast(count)];
        var i: usize = 1;
        while (i < labels.len) : (i += 1) if (labels[i - 1] >= labels[i]) return error.Corrupt;
        return .{ .final = final, .final_out = final_out, .labels = labels, .pairs = at + labels.len };
    }

    /// The transition at `at.*` of the node at `address`, `at` moved past it.
    fn pairAt(f: Fst, at: *usize, address: u64) Error!Pair {
        const out = try varint.read(f.nodes, at);
        const back = try varint.read(f.nodes, at);
        if (back == 0 or back > address) return error.Corrupt;
        return .{ .out = out, .target = address - back };
    }

    /// Where a walk of the keys stands: a node, which of its transitions
    /// comes next and where it is read from, and the output reaching it.
    pub const Frame = struct { address: u64, next: u16, at: usize, out: u64, final_done: bool };

    /// The keys starting with `prefix`, in order, with their values: `key`
    /// holds the longest key the walk may meet, and `frames` one more than
    /// that. A key longer is `error.KeyTooLong`.
    pub fn walk(f: Fst, prefix: []const u8, key: []u8, frames: []Frame) Error!Walk {
        aegis.assert.invariant(frames.len == key.len + 1, "a walk's frames are one per byte of its longest key, and one");
        var w: Walk = .{ .fst = f, .key = key, .frames = frames, .depth = 0, .len = 0 };
        if (prefix.len > key.len) return w;
        var address = f.root;
        var out: u64 = 0;
        for (prefix) |label| {
            const node = try f.nodeAt(address);
            const i = std.mem.findScalar(u8, node.labels, label) orelse return w;
            var at = node.pairs;
            var t: Pair = undefined;
            for (0..i + 1) |_| t = try f.pairAt(&at, address);
            out = std.math.add(u64, out, t.out) catch return error.Corrupt;
            address = t.target;
        }
        @memcpy(key[0..prefix.len], prefix);
        const node = try f.nodeAt(address);
        frames[0] = .{ .address = address, .next = 0, .at = node.pairs, .out = out, .final_done = false };
        w.depth = 1;
        w.len = prefix.len;
        return w;
    }

    /// A walk of keys in order, depth first, a key before the keys it is a
    /// prefix of; iterative, its depth bounded by its key buffer.
    pub const Walk = struct {
        fst: Fst,
        key: []u8,
        frames: []Frame,
        /// Frames in use.
        depth: usize,
        /// The key's length at the top frame.
        len: usize,

        pub const Entry = struct { key: []const u8, value: u64 };

        pub fn next(w: *Walk) (Error || error{KeyTooLong})!?Entry {
            return w.nextWith(Every{});
        }

        /// What a visitor's `descend` fails with, the visitor given by value
        /// or by pointer.
        fn VisitorError(comptime V: type) type {
            return switch (@typeInfo(V)) {
                .pointer => |ptr| ptr.child.Error,
                else => V.Error,
            };
        }

        /// Every key: a visitor that passes over nothing.
        pub const Every = struct {
            pub const Error = error{};
            pub fn descend(_: Every, _: []const u8) error{}!bool {
                return true;
            }
        };

        /// The next key `visitor` leads to. Before the walk takes a byte it
        /// asks `visitor.descend(key)`, `key` the bytes to that byte and the
        /// byte itself; false passes over every key below it, where the
        /// visitor knows none can be wanted. A key returned is one the
        /// visitor descended to byte by byte; accepting it is the caller's.
        pub fn nextWith(w: *Walk, visitor: anytype) (Error || error{KeyTooLong} || VisitorError(@TypeOf(visitor)))!?Entry {
            while (w.depth != 0) {
                const top = &w.frames[w.depth - 1];
                const node = try w.fst.nodeAt(top.address);
                if (!top.final_done) {
                    top.final_done = true;
                    if (node.final) return .{ .key = w.key[0..w.len], .value = std.math.add(u64, top.out, node.final_out) catch return error.Corrupt };
                }
                if (top.next < node.labels.len) {
                    const label = node.labels[top.next];
                    const t = try w.fst.pairAt(&top.at, top.address);
                    top.next += 1;
                    if (w.len == w.key.len) return error.KeyTooLong;
                    w.key[w.len] = label;
                    if (!try visitor.descend(w.key[0 .. w.len + 1])) continue;
                    const child = try w.fst.nodeAt(t.target);
                    w.len += 1;
                    w.frames[w.depth] = .{ .address = t.target, .next = 0, .at = child.pairs, .out = std.math.add(u64, top.out, t.out) catch return error.Corrupt, .final_done = false };
                    w.depth += 1;
                    continue;
                }
                w.depth -= 1;
                if (w.depth != 0) w.len -= 1;
            }
            return null;
        }
    };
};
