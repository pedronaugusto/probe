//! The bounds on what probe takes from outside: a document, a term, a query
//! and what a query may expand to. Each is checked before the work it
//! bounds, and passing one is an error named for it, never a slow call.
//!
//! This file is internal. `probe.zig` is the package.

/// The most bytes of text one document's fields hold together
/// (`error.FieldTooLong` past it, before it is analyzed).
document_bytes: u32 = 16 * 1024 * 1024,
/// The longest term, in bytes: a longer word is indexed cut to it.
term_bytes: u16 = 255,
/// The most terms a prefix expands to (`error.TooManyTerms` past it).
expansions: u32 = 1024,
/// The most clauses a query holds (`error.TooManyClauses`).
clauses: u32 = 1024,
/// The deepest a query nests (`error.TooDeep`).
depth: u16 = 64,
