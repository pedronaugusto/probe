//! The index of a document type: its writer, its snapshots and its queries,
//! typed by the document. `Index(Doc)` reads `Doc`'s `pub const probe`
//! declaration (`Schema.zig`) once, at compile time; a field is named by
//! `Index(Doc).Field`, so a field that is not declared does not compile.
//!
//! This file is internal. `probe.zig` is the package.
const std = @import("std");
const aegis = @import("aegis");
const airlock = @import("airlock");
const Schema = @import("Schema.zig");
const Limits = @import("Limits.zig");
const ids = @import("ids.zig");
const Manifest = @import("Manifest.zig");
const committed = @import("committed.zig");
const merge = @import("merge.zig");
const InnerWriter = @import("Writer.zig");
const InnerReader = @import("Reader.zig");
const query = @import("query.zig");
const segment = @import("segment.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Node = query.Tree.Node;

/// Why an index did not open, and on which file: the first field or limit
/// that differs for `SchemaMismatch`, the file a check refused for the
/// others where it is known.
pub const OpenDiagnostic = struct {
    mismatch: Manifest.Mismatch = .{},
    failed: committed.Failed = .{},

    /// The file the open failed on, if known.
    pub fn file(d: *const OpenDiagnostic) ?[]const u8 {
        return if (d.failed.len == 0) null else d.failed.name();
    }
};

/// Which segment of which snapshot a hit is of: the snapshot's commit, the
/// segment's place in it and its number. A hit is read only by the
/// snapshot it came from (`StaleHit` otherwise).
pub const SegmentRef = struct {
    generation: u64,
    index: u32,
    number: u64,
};

/// How many documents matched: exactly, or at least this many.
pub const Total = struct {
    value: u64,
    relation: enum { exact, at_least },
};

pub const OpenError = error{ NotFound, Locked, Busy, Corrupt, VersionTooNew, SchemaMismatch, Canceled, ReadFailed, WriteFailed, OutOfMemory };
pub const AddError = error{ FieldTooLong, Corrupt, Canceled, ReadFailed, OutOfMemory };
pub const FlushError = error{ Corrupt, Canceled, ReadFailed, OutOfMemory };
pub const CommitError = InnerWriter.CommitError;
pub const MergeError = InnerWriter.MergeError;
pub const QueryParseError = query.parse.Error;
pub const SearchError = error{ TooManyTerms, StaleHit, Canceled, ReadFailed, Corrupt, OutOfMemory };
pub const StoredError = error{ StaleHit, Canceled, ReadFailed, Corrupt, OutOfMemory };

/// A merge done: the commit that holds it, the segment it wrote, how many
/// it took the place of, and its documents.
pub const MergeReport = InnerWriter.MergeReport;

pub fn Index(comptime Doc: type) type {
    const S = Schema.Of(Doc);
    const fields = S.all;
    const id_name = S.id_field;
    return struct {
        const Self = @This();

        /// A field of `Doc`; only the declared ones are taken.
        pub const Field = std.meta.FieldEnum(Doc);
        /// The id a document is named by.
        pub const Id = ids.Id(Doc);
        /// The fields `Doc` stores, as `Doc` types them: what `stored`
        /// gives back, and nothing it cannot fill.
        pub const Stored = StoredOf(Doc, fields);

        pub const Options = struct {
            limits: Limits = .{},
            /// How far a commit's files reach before it returns.
            durability: airlock.Level = .data,
            /// A segment is flushed once its documents' bytes pass this.
            buffer: aegis.units.Bytes(usize) = .literal("64MiB"),
            /// Which segments `mergeStep` merges.
            merge: merge.Policy = .{},
            /// The commits whose files stay for other processes' readers.
            keep_commits: aegis.int.Ranged(u8, 1, 64) = .literal(2),
            /// Told why the index did not open.
            diagnostic: ?*OpenDiagnostic = null,
        };

        pub const ReadOptions = struct {
            limits: Limits = .{},
            /// How many times a manifest whose files went is read again.
            retries: u8 = 8,
            /// Told why the index did not open.
            diagnostic: ?*OpenDiagnostic = null,
        };

        /// The place of `field` among the declared ones.
        fn placeOf(comptime field: Field) u32 {
            return @intCast(S.indexOf(@tagName(field)));
        }

        /// Takes the directory's writer lock (`Locked` if another holds it)
        /// and opens the newest commit.
        pub fn openWriter(gpa: Allocator, io: Io, dir: Io.Dir, options: Options) OpenError!*Writer {
            const w = try gpa.create(Writer);
            errdefer gpa.destroy(w);
            const d = options.diagnostic;
            w.* = .{
                .gpa = gpa,
                .limits = options.limits,
                .inner = try .open(gpa, io, dir, fields, .{
                    .term_bytes = options.limits.term_bytes,
                    .durability = options.durability,
                    .buffer_bytes = options.buffer.raw(),
                    .keep_commits = options.keep_commits.raw(),
                    .merge = options.merge,
                    .mismatch = if (d) |x| &x.mismatch else null,
                    .failed = if (d) |x| &x.failed else null,
                }),
            };
            return w;
        }

        /// Opens the newest commit and every file it names.
        pub fn openReader(gpa: Allocator, io: Io, dir: Io.Dir, options: ReadOptions) OpenError!*Reader {
            const d = options.diagnostic;
            const inner = try InnerReader.open(gpa, io, dir, fields, .{
                .term_bytes = options.limits.term_bytes,
                .retries = options.retries,
                .mismatch = if (d) |x| &x.mismatch else null,
                .failed = if (d) |x| &x.failed else null,
            });
            return Reader.wrap(gpa, inner, options.limits);
        }

        pub const Writer = struct {
            gpa: Allocator,
            limits: Limits,
            inner: InnerWriter,

            /// Adds `doc`; `FieldTooLong` when its text passes
            /// `Limits.document_bytes`, before it is analyzed.
            pub fn add(w: *Writer, io: Io, doc: Doc) AddError!void {
                var values: [fields.len]segment.write.Value = undefined;
                try w.documentOf(&doc, &values);
                try w.inner.add(io, .{ .id = idOf(&doc), .values = &values });
            }

            /// Deletes every document added with `id` before.
            pub fn delete(w: *Writer, id: Id) AddError!void {
                try w.inner.delete(id.raw());
            }

            /// Deletes the documents of `doc`'s id, then adds `doc`.
            pub fn update(w: *Writer, io: Io, doc: Doc) AddError!void {
                var values: [fields.len]segment.write.Value = undefined;
                try w.documentOf(&doc, &values);
                try w.inner.update(io, .{ .id = idOf(&doc), .values = &values });
            }

            /// Closes what was added since into a segment the writer's
            /// snapshots see; not durable.
            pub fn refresh(w: *Writer, io: Io) FlushError!void {
                try w.inner.refresh(io);
            }

            /// Makes what was added durable: the files synced, then the
            /// manifest replaced. Its generation, which names the commit.
            pub fn commit(w: *Writer, io: Io) CommitError!aegis.own.MustUse(u64, "a commit's generation names what it made durable") {
                return .init(try w.inner.commit(io));
            }

            /// One merge the policy chooses, if one is due.
            pub fn mergeStep(w: *Writer, io: Io) MergeError!aegis.own.MustUse(?MergeReport, "a merge's report says whether one was due") {
                return .init(try w.inner.mergeStep(io, null));
            }

            /// A snapshot of what the writer holds: what `refresh` closed
            /// since the last commit included.
            pub fn reader(w: *const Writer) OpenError!*Reader {
                return Reader.wrap(w.gpa, try w.inner.reader(), w.limits);
            }

            /// Lets the lock go; what is not committed is dropped.
            pub fn deinit(w: *Writer, io: Io) void {
                w.inner.deinit(io);
                w.gpa.destroy(w);
            }

            fn documentOf(w: *const Writer, doc: *const Doc, out: *[fields.len]segment.write.Value) error{FieldTooLong}!void {
                var text: u64 = 0;
                inline for (fields, 0..) |f, i| {
                    const value = @field(doc.*, f.name);
                    out[i] = switch (f.kind) {
                        .text => .{ .text = value },
                        .keyword => .{ .keyword = value },
                        .numeric => .{ .numeric = Schema.columnValue(value) },
                    };
                    if (f.kind != .numeric) text += value.len;
                }
                if (text > w.limits.document_bytes) return error.FieldTooLong;
            }
        };

        fn idOf(doc: *const Doc) u64 {
            const v = @field(doc.*, id_name);
            return if (@TypeOf(v) == u64) v else v.raw();
        }

        /// A document a query matched.
        pub const Hit = struct {
            id: Id,
            score: f32,
            segment: SegmentRef,
            doc: ids.DocId,
        };

        /// Where a page of hits ended, so the next goes on from it: valid
        /// only on the snapshot that gave it.
        pub const Cursor = struct {
            segment: SegmentRef,
            last: query.exec.Hit,
        };

        pub const Sort = union(enum) {
            score,
            /// By a numeric field's value.
            field: struct { by: Field, order: enum { ascending, descending } = .ascending },
        };

        pub const SearchOptions = struct {
            /// The most hits to give.
            top: aegis.int.Ranged(u32, 1, 10_000) = .literal(10),
            sort: Sort = .score,
            /// The page after this one's last hit.
            after: ?Cursor = null,
            /// Matches are counted exactly up to this many, and past it
            /// the total is at least this many (Lucene's total hits
            /// threshold); `maxInt` counts all.
            count_up_to: u64 = 1000,
        };

        pub const Hits = struct {
            gpa: Allocator,
            hits: []const Hit,
            total: Total,
            /// Where the next page starts, when this one is full.
            next: ?Cursor,

            pub fn deinit(h: *Hits) void {
                h.gpa.free(h.hits);
                h.* = undefined;
            }
        };

        pub const Reader = struct {
            gpa: Allocator,
            limits: Limits,
            inner: InnerReader,

            fn wrap(gpa: Allocator, inner: InnerReader, limits: Limits) OpenError!*Reader {
                var held = inner;
                errdefer held.deinit();
                const r = try gpa.create(Reader);
                r.* = .{ .gpa = gpa, .limits = limits, .inner = held };
                return r;
            }

            /// The commit the snapshot is of.
            pub fn generation(r: *const Reader) u64 {
                return r.inner.generation;
            }

            /// The best hits of `q`, as `options.sort` orders them.
            pub fn search(r: *const Reader, io: Io, q: *const Query, options: SearchOptions) SearchError!Hits {
                const order: query.exec.Order = switch (options.sort) {
                    .score => .score,
                    .field => |f| o: {
                        const place = fieldPlace(f.by);
                        aegis.assert.invariant(place != null and fields[place.?].kind == .numeric, "a search is sorted by a declared numeric field");
                        break :o .{ .column = .{ .field = place.?, .descending = f.order == .descending } };
                    },
                };
                const after: ?query.exec.Hit = if (options.after) |c| a: {
                    try r.check(c.segment);
                    break :a c.last;
                } else null;
                var report: query.exec.Report = .{};
                const found = try query.exec.search(r.gpa, io, &r.inner, &q.tree.root, .{ .top = options.top.raw(), .limits = r.limits, .order = order, .after = after, .report = &report });
                defer r.gpa.free(found);
                const n = if (report.pruned)
                    try query.exec.countUpTo(r.gpa, io, &r.inner, &q.tree.root, r.limits, options.count_up_to)
                else
                    report.scored;
                const total: Total = if (n > options.count_up_to) .{ .value = options.count_up_to, .relation = .at_least } else .{ .value = n, .relation = .exact };
                const hits = try r.gpa.alloc(Hit, found.len);
                errdefer r.gpa.free(hits);
                for (found, hits) |f, *h| {
                    const s = &r.inner.segments[f.segment];
                    h.* = .{
                        .id = .fromRaw(s.read().idOf(f.doc)),
                        .score = f.score,
                        .segment = r.refOf(f.segment),
                        .doc = ids.DocId.from(f.doc, s.docs()) catch aegis.assert.never("a hit's doc is in its segment"),
                    };
                }
                // A full page may have one after it; an empty one, below the
                // range, has not.
                const full = if (@TypeOf(options.top).init(@intCast(found.len))) |len| len.eql(options.top) else |_| false;
                const next: ?Cursor = if (full) .{ .segment = r.refOf(found[found.len - 1].segment), .last = found[found.len - 1] } else null;
                return .{ .gpa = r.gpa, .hits = hits, .total = total, .next = next };
            }

            /// How many live documents match `q`: matched, never scored.
            pub fn count(r: *const Reader, io: Io, q: *const Query) SearchError!u64 {
                return query.exec.count(r.gpa, io, &r.inner, &q.tree.root, r.limits);
            }

            /// The stored fields of `hit`, a hit of this snapshot, their
            /// bytes on `arena`.
            pub fn stored(r: *const Reader, io: Io, hit: Hit, arena: Allocator) StoredError!Stored {
                try r.check(hit.segment);
                const s = &r.inner.segments[hit.segment.index];
                const doc = hit.doc.raw();
                if (doc >= s.docs()) return error.StaleHit;
                var values: [storedCount(fields)]segment.store.Value = undefined;
                var buffer: std.ArrayList(u8) = .empty;
                defer buffer.deinit(r.gpa);
                try s.read().storedOf(io, r.gpa, doc, &buffer, &values);
                var out: Stored = undefined;
                comptime var n = 0;
                inline for (fields) |f| {
                    if (!f.stored) continue;
                    const T = @FieldType(Doc, f.name);
                    @field(out, f.name) = switch (f.kind) {
                        .text, .keyword => switch (values[n]) {
                            .bytes => |b| try arena.dupe(u8, b),
                            .numeric => return error.Corrupt,
                        },
                        .numeric => switch (values[n]) {
                            .numeric => |v| try fromColumn(T, v),
                            .bytes => return error.Corrupt,
                        },
                    };
                    n += 1;
                }
                return out;
            }

            /// A snapshot of the newest commit; this one stays as it is.
            pub fn reopen(r: *const Reader, io: Io) OpenError!*Reader {
                return wrap(r.gpa, try r.inner.reopen(io), r.limits);
            }

            pub fn deinit(r: *Reader) void {
                r.inner.deinit();
                r.gpa.destroy(r);
            }

            fn refOf(r: *const Reader, index: u32) SegmentRef {
                return .{ .generation = r.inner.generation, .index = index, .number = r.inner.segments[index].number() };
            }

            /// `StaleHit` unless `ref` is of this snapshot.
            fn check(r: *const Reader, ref: SegmentRef) error{StaleHit}!void {
                if (ref.generation != r.inner.generation or ref.index >= r.inner.segments.len) return error.StaleHit;
                if (r.inner.segments[ref.index].number() != ref.number) return error.StaleHit;
            }
        };

        /// The place of `field` among the declared ones, or null.
        fn fieldPlace(field: Field) ?u32 {
            inline for (fields, 0..) |f, i| if (std.mem.eql(u8, f.name, @tagName(field))) return @intCast(i);
            return null;
        }

        /// A query: parsed from the language, or built in code. Words go
        /// through each field's analysis either way.
        pub const Query = struct {
            tree: query.Tree,

            pub const ParseOptions = struct {
                /// The fields a word with no field searches; every text
                /// field when null.
                fields: ?[]const Field = null,
                limits: Limits = .{},
                /// Told where and why the query does not read.
                diagnostic: ?*query.parse.Diagnostic = null,
            };

            pub fn parse(gpa: Allocator, text: aegis.input.Untrusted([]const u8), options: ParseOptions) QueryParseError!Query {
                var names: [fields.len][]const u8 = undefined;
                const named: ?[]const []const u8 = if (options.fields) |list| n: {
                    if (list.len > names.len) return error.Invalid;
                    for (list, names[0..list.len]) |f, *name| name.* = @tagName(f);
                    break :n names[0..list.len];
                } else null;
                return .{ .tree = try query.parse.parse(gpa, fields, text, .{ .fields = named, .limits = options.limits, .diagnostic = options.diagnostic }) };
            }

            pub fn deinit(q: *Query) void {
                q.tree.deinit();
                q.* = undefined;
            }

            /// A query's clauses, built on one arena and made a query by
            /// `build`.
            pub const Builder = struct {
                arena: std.heap.ArenaAllocator,
                limits: Limits = .{},

                pub fn init(gpa: Allocator) Builder {
                    return .{ .arena = .init(gpa) };
                }

                /// Frees what `build` did not take.
                pub fn deinit(b: *Builder) void {
                    b.arena.deinit();
                    b.* = undefined;
                }

                /// The clauses so far as a query, checked against the
                /// schema and the limits; the builder is then spent.
                pub fn build(b: *Builder, root: Clause) query.Tree.CheckError!Query {
                    try query.Tree.check(&root.node, fields, b.limits);
                    const tree: query.Tree = .{ .arena = b.arena, .root = root.node };
                    b.arena = .init(b.arena.child_allocator);
                    return .{ .tree = tree };
                }

                /// A word of a text or keyword field, as the language reads
                /// it: one term, the phrase of its parts, or bytes as they
                /// are; nothing when it analyzes to nothing.
                pub fn term(b: *Builder, comptime field: Field, text: []const u8) QueryParseError!Clause {
                    comptime notNumeric(field);
                    return b.clauseOf(try query.parse.wordClause(b.arena.allocator(), fields, b.limits, placeOf(field), text, false));
                }

                pub fn phrase(b: *Builder, comptime field: Field, text: []const u8, slop: u32) QueryParseError!Clause {
                    comptime notNumeric(field);
                    return b.clauseOf(try query.parse.phraseClause(b.arena.allocator(), fields, b.limits, placeOf(field), text, slop));
                }

                pub fn prefix(b: *Builder, comptime field: Field, text: []const u8) QueryParseError!Clause {
                    comptime notNumeric(field);
                    return b.clauseOf(try query.parse.wordClause(b.arena.allocator(), fields, b.limits, placeOf(field), text, true));
                }

                /// The documents holding a term of `field` that `pattern`
                /// matches whole, as `/pattern/` reads: folded and
                /// case-insensitive on a text field, bytes as they are on a
                /// keyword field. `error.Invalid` where it does not compile.
                pub fn regex(b: *Builder, comptime field: Field, pattern: []const u8) QueryParseError!Clause {
                    comptime notNumeric(field);
                    return b.clauseOf(try query.parse.patternClause(b.arena.allocator(), fields, b.limits, placeOf(field), pattern));
                }

                /// The documents whose `field` lies from `min` to `max`,
                /// both included; null for no bound.
                pub fn range(b: *Builder, comptime field: Field, min: ?@FieldType(Doc, @tagName(field)), max: ?@FieldType(Doc, @tagName(field))) Clause {
                    _ = b;
                    if (comptime fields[placeOf(field)].kind != .numeric) @compileError("probe: a range is of a numeric field, and `" ++ @tagName(field) ++ "` is not");
                    return .{ .node = .{ .range = .{
                        .field = placeOf(field),
                        .min = if (min) |v| Schema.columnValue(v) else 0,
                        .max = if (max) |v| Schema.columnValue(v) else std.math.maxInt(u64),
                    } } };
                }

                pub fn all(_: *Builder) Clause {
                    return .{ .node = .all };
                }

                pub fn none(_: *Builder) Clause {
                    return .{ .node = .none };
                }

                pub fn @"and"(b: *Builder, clauses: []const Clause) Allocator.Error!Clause {
                    return .{ .node = .{ .@"and" = try b.nodes(clauses) } };
                }

                pub fn @"or"(b: *Builder, clauses: []const Clause) Allocator.Error!Clause {
                    return .{ .node = .{ .@"or" = try b.nodes(clauses) } };
                }

                pub fn not(b: *Builder, clause: Clause) Allocator.Error!Clause {
                    const n = try b.arena.allocator().create(Node);
                    n.* = clause.node;
                    return .{ .node = .{ .not = n } };
                }

                /// `clause` scored `by` times; `by` finite and not below 0.
                pub fn boost(b: *Builder, clause: Clause, by: f32) Allocator.Error!Clause {
                    const n = try b.arena.allocator().create(Node);
                    n.* = clause.node;
                    return .{ .node = .{ .boost = .{ .node = n, .by = by } } };
                }

                fn nodes(b: *Builder, clauses: []const Clause) Allocator.Error![]const Node {
                    const out = try b.arena.allocator().alloc(Node, clauses.len);
                    for (out, clauses) |*o, c| o.* = c.node;
                    return out;
                }

                fn clauseOf(_: *Builder, n: ?Node) Clause {
                    return .{ .node = n orelse .none };
                }

                fn notNumeric(comptime field: Field) void {
                    if (comptime fields[placeOf(field)].kind == .numeric) @compileError("probe: `" ++ @tagName(field) ++ "` is numeric: a range names its values");
                }
            };

            /// A clause of a query being built.
            pub const Clause = struct { node: Node };
        };
    };
}

fn storedCount(comptime fields: []const Schema.Field) usize {
    var n: usize = 0;
    for (fields) |f| n += @intFromBool(f.stored);
    return n;
}

/// The struct of `Doc`'s stored fields, each of `Doc`'s type.
fn StoredOf(comptime Doc: type, comptime fields: []const Schema.Field) type {
    const n = storedCount(fields);
    var names: [n][]const u8 = undefined;
    var types: [n]type = undefined;
    var i: usize = 0;
    for (fields) |f| {
        if (!f.stored) continue;
        names[i] = f.name;
        types[i] = @FieldType(Doc, f.name);
        i += 1;
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

/// A column value back as a `T`, `Schema.columnValue`'s inverse; `Corrupt`
/// when it is not a value of `T`.
fn fromColumn(comptime T: type, v: u64) error{Corrupt}!T {
    const R = Schema.ColumnRepr(T);
    const raw: R = if (R == u64) v else @bitCast(v ^ (@as(u64, 1) << 63));
    if (T == R) return raw;
    const made = T.fromRaw(raw);
    return if (@typeInfo(@TypeOf(made)) == .error_union) made catch error.Corrupt else made;
}
