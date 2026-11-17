//! The numbers probe hands out and takes back: a document's place in its
//! segment, and the id the program gives each document.
//!
//! This file is internal. `probe.zig` is the package.
const aegis = @import("aegis");

/// The domain of `DocId`: places in one segment.
pub const SegmentDocs = struct {};

/// A document's place in its segment, from 0. Which segment it is of is
/// checked where it is used: a doc id never indexes another segment's
/// columns.
pub const DocId = aegis.handle.Index(SegmentDocs, u32);

/// The id the program gives each document of type `Doc`, which `delete` and
/// `update` name it by, and a hit carries.
pub fn Id(comptime Doc: type) type {
    return aegis.id.Id(Doc, u64);
}
