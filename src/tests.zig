//! Test assembly stays above the public package root.
const std = @import("std");
const probe = @import("probe.zig");

test {
    std.testing.refAllDecls(probe);
    _ = @import("bitpack_test.zig");
    _ = @import("fst_test.zig");
    _ = @import("bitmap_test.zig");
    _ = @import("schema_test.zig");
    _ = @import("analysis_test.zig");
    _ = @import("segment_files_test.zig");
    _ = @import("postings_test.zig");
    _ = @import("positions_test.zig");
    _ = @import("terms_test.zig");
    _ = @import("columns_test.zig");
    _ = @import("store_test.zig");
    _ = @import("segment_test.zig");
    _ = @import("manifest_test.zig");
    _ = @import("sources_test.zig");
    _ = @import("writer_test.zig");
    _ = @import("reader_test.zig");
    _ = @import("merge_test.zig");
    _ = @import("bm25_test.zig");
    _ = @import("query_test.zig");
    _ = @import("concurrency_test.zig");
    _ = @import("crash_test.zig");
}
