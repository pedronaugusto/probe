//! What a project that depends on probe writes. Built by
//! `zig build check-consumer` with only aegis to fetch, so probe's build.zig
//! must work without any of its own CI dependencies.
const probe = @import("probe");

pub fn main() void {
    var block: [probe.bitpack.block_len]u32 = @splat(0);
    var out: [probe.bitpack.max_block_bytes]u8 = undefined;
    probe.bitpack.pack(&block, probe.bitpack.bitsFor(&block), &out);
    probe.bitpack.unpack(&.{}, 0, &block);
}
