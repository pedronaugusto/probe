//! Unsigned LEB128 integers: seven bits a byte, low first, the high bit set
//! on every byte but the last. One spelling for each value: a read refuses
//! bits past 64 and a run that never ends.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{Corrupt};

/// The most bytes a `u64` takes.
pub const max_bytes = 10;

/// `value` appended to `out`.
pub fn append(gpa: Allocator, out: *std.ArrayList(u8), value: u64) Allocator.Error!void {
    var v = value;
    while (v >= 0x80) : (v >>= 7) try out.append(gpa, @as(u8, @truncate(v)) | 0x80);
    try out.append(gpa, @truncate(v));
}

/// The value at `at.*` in `bytes`, with `at` moved past it.
pub fn read(bytes: []const u8, at: *usize) Error!u64 {
    var value: u64 = 0;
    var shift: u7 = 0;
    while (true) {
        if (at.* >= bytes.len or shift > 63) return error.Corrupt;
        const byte = bytes[at.*];
        at.* += 1;
        const part: u64 = byte & 0x7f;
        if (shift == 63 and part > 1) return error.Corrupt;
        value |= part << @intCast(shift);
        if (byte & 0x80 == 0) return value;
        shift += 7;
    }
}

/// As `read`, refusing a value past `max`.
pub fn readAtMost(bytes: []const u8, at: *usize, max: u64) Error!u64 {
    const value = try read(bytes, at);
    if (value > max) return error.Corrupt;
    return value;
}

/// The bytes a length at `at.*` in `bytes` gives, those after it, with
/// `at` moved past them. A length is bounded by the bytes left once it is
/// read, so one longer than what follows it is refused.
pub fn readBytes(bytes: []const u8, at: *usize) Error![]const u8 {
    const len = try read(bytes, at);
    if (len > bytes.len - at.*) return error.Corrupt;
    const out = bytes[at.*..][0..@intCast(len)];
    at.* += out.len;
    return out;
}
