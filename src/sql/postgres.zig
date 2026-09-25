//! PostgreSQL spellings for `root.zig`: type mapping, identifier quoting,
//! primary keys, literals, named defaults, the renames that follow a
//! renamed table, the tracking table's catalog lookup, the migration
//! lock, timeouts, the schema and the database lookup.

const std = @import("std");
const Writer = std.Io.Writer;
const ast = @import("../mig/ast.zig");
const root = @import("root.zig");

pub const capabilities: root.Capabilities = .{
    .transactional_ddl = true,
    .advisory_lock = true,
};

/// `"name"`, with embedded `"` doubled.
pub fn identifier(w: *Writer, name: []const u8) Writer.Error!void {
    return identifierParts(w, &.{name});
}

/// The concatenation of `parts` as one quoted identifier.
pub fn identifierParts(w: *Writer, parts: []const []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (parts) |part| try escaped(w, part, '"');
    try w.writeByte('"');
}

/// `s` with each `quote` doubled.
fn escaped(w: *Writer, s: []const u8, quote: u8) Writer.Error!void {
    var rest = s;
    while (std.mem.indexOfScalar(u8, rest, quote)) |i| {
        try w.writeAll(rest[0 .. i + 1]);
        try w.writeByte(quote);
        rest = rest[i + 1 ..];
    }
    try w.writeAll(rest);
}

pub fn primaryKey(w: *Writer, id: ast.IdKind) Writer.Error!void {
    try w.writeAll(switch (id) {
        .bigint => "\"id\" bigserial PRIMARY KEY",
        .uuid => "\"id\" uuid PRIMARY KEY DEFAULT gen_random_uuid()",
        .none => unreachable,
    });
}

pub fn columnType(w: *Writer, c: ast.Column) Writer.Error!void {
    switch (c.type) {
        .string => if (c.limit) |n| try w.print("varchar({d})", .{n}) else try w.writeAll("varchar"),
        .decimal => if (c.precision) |p| {
            if (c.scale) |s| try w.print("numeric({d}, {d})", .{ p, s }) else try w.print("numeric({d})", .{p});
        } else try w.writeAll("numeric"),
        .text => try w.writeAll("text"),
        .integer => try w.writeAll("integer"),
        .bigint => try w.writeAll("bigint"),
        .float => try w.writeAll("double precision"),
        .boolean => try w.writeAll("boolean"),
        .date => try w.writeAll("date"),
        .datetime => try w.writeAll(if (c.time_zone) "timestamptz(6)" else "timestamp(6)"),
        .time => try w.writeAll("time"),
        .binary => try w.writeAll("bytea"),
        .uuid => try w.writeAll("uuid"),
        .json => try w.writeAll("jsonb"),
    }
}

/// Strings are single-quoted with `'` doubled. Backslashes are literal
/// under `standard_conforming_strings`, the default since PostgreSQL 9.1.
pub fn literal(w: *Writer, l: ast.Literal) Writer.Error!void {
    switch (l) {
        .string => |s| try w.print("{f}", .{StringLiteral{ .parts = &.{s} }}),
        .integer => |i| try w.print("{d}", .{i}),
        .decimal => |d| try w.writeAll(d),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .nil => try w.writeAll("NULL"),
    }
}

/// `CURRENT_TIMESTAMP` fits `date` and `time` columns too, through
/// PostgreSQL's assignment casts, so the column's type (null when the
/// operation does not know it) does not matter. `gen_random_uuid()` is
/// built in since PostgreSQL 13.
pub fn namedDefault(w: *Writer, n: ast.NamedDefault, _: ?ast.ColumnType) Writer.Error!void {
    try w.writeAll(switch (n) {
        .now => "CURRENT_TIMESTAMP",
        .uuid => "gen_random_uuid()",
    });
}

/// The keyword after `CREATE INDEX` and `DROP INDEX`.
pub fn indexAlgorithm(a: ast.IndexAlgorithm) []const u8 {
    return switch (a) {
        .concurrently => "CONCURRENTLY",
    };
}

/// Follows `ALTER TABLE <from> RENAME TO <to>` with a `DO` block that
/// renames what is named after the table by default, as if it had been
/// created as `to`: the indexes `index_<from>_on_*` and foreign keys
/// `fk_<from>_on_*` that ffmig names, and PostgreSQL's own primary key
/// `<from>_pkey` and `id` sequence `<from>_id_seq`. Other names are left
/// alone. Which of these exist is only known at run time, so the block
/// reads the catalog. A new name longer than an identifier may be is an
/// error, where PostgreSQL would cut it short.
pub fn renameDefaultNames(w: *Writer, from: []const u8, to: []const u8) Writer.Error!void {
    try w.print(
        \\;
        \\DO $$
        \\DECLARE
        \\  t regclass := quote_ident({[to]f})::regclass;
        \\  r record;
        \\BEGIN
        \\  FOR r IN
        \\    SELECT format('ALTER INDEX %s RENAME', c.oid::regclass) AS rename_sql, c.relname AS old_name,
        \\      CASE WHEN starts_with(c.relname, {[from_index]f})
        \\      THEN {[to_index]f} || substr(c.relname, char_length({[from_index]f}) + 1)
        \\      ELSE {[to_pkey]f} END AS new_name
        \\    FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
        \\    WHERE i.indrelid = t
        \\      AND (starts_with(c.relname, {[from_index]f}) OR i.indisprimary AND c.relname = {[from_pkey]f})
        \\    UNION ALL
        \\    SELECT format('ALTER TABLE %s RENAME CONSTRAINT %I', t, conname), conname,
        \\      {[to_fk]f} || substr(conname, char_length({[from_fk]f}) + 1)
        \\    FROM pg_constraint
        \\    WHERE conrelid = t AND contype = 'f' AND starts_with(conname, {[from_fk]f})
        \\    UNION ALL
        \\    SELECT format('ALTER SEQUENCE %s RENAME', s.oid::regclass), s.relname, {[to_seq]f}
        \\    FROM pg_depend d JOIN pg_class s ON s.oid = d.objid AND d.classid = 'pg_class'::regclass
        \\    WHERE d.refobjid = t AND s.relkind = 'S' AND s.relname = {[from_seq]f}
        \\  LOOP
        \\    IF octet_length(r.new_name) > current_setting('max_identifier_length')::int THEN
        \\      RAISE EXCEPTION 'cannot rename % to %: longer than % bytes',
        \\        r.old_name, r.new_name, current_setting('max_identifier_length');
        \\    END IF;
        \\    EXECUTE r.rename_sql || format(' TO %I', r.new_name);
        \\  END LOOP;
        \\END
        \\$$
    , .{
        .to = StringLiteral{ .parts = &.{to} },
        .to_pkey = StringLiteral{ .parts = &.{ to, "_pkey" } },
        .from_pkey = StringLiteral{ .parts = &.{ from, "_pkey" } },
        .to_index = StringLiteral{ .parts = &.{ "index_", to, "_on_" } },
        .from_index = StringLiteral{ .parts = &.{ "index_", from, "_on_" } },
        .to_fk = StringLiteral{ .parts = &.{ "fk_", to, "_on_" } },
        .from_fk = StringLiteral{ .parts = &.{ "fk_", from, "_on_" } },
        .to_seq = StringLiteral{ .parts = &.{ to, "_id_seq" } },
        .from_seq = StringLiteral{ .parts = &.{ from, "_id_seq" } },
    });
}

/// The concatenation of `parts` as one string literal, for `{f}`.
const StringLiteral = struct {
    parts: []const []const u8,

    pub fn format(l: StringLiteral, w: *Writer) Writer.Error!void {
        try w.writeByte('\'');
        for (l.parts) |part| try escaped(w, part, '\'');
        try w.writeByte('\'');
    }
};

/// Key of the advisory lock: "ffmig" in ASCII. PostgreSQL scopes advisory
/// locks to the current database, so runs on different databases of one
/// server never wait for each other.
const lock_key = std.mem.readInt(u40, "ffmig", .big);

/// A session-level advisory lock: it outlives each migration's
/// transaction, and the server releases it if the connection drops.
pub fn lock(w: *Writer, l: root.Lock) Writer.Error!void {
    switch (l) {
        .try_lock => try w.print("SELECT 1 WHERE pg_try_advisory_lock({d})", .{lock_key}),
        .unlock => try w.print("SELECT pg_advisory_unlock({d})", .{lock_key}),
    }
}

/// `SET` without `LOCAL` lasts for the session, so it covers every
/// migration of the run, `transaction: false` ones included.
pub fn timeout(w: *Writer, t: root.Timeout) Writer.Error!void {
    switch (t) {
        .lock => |ms| try w.print("SET lock_timeout = '{d}ms'", .{ms}),
        .statement => |ms| try w.print("SET statement_timeout = '{d}ms'", .{ms}),
    }
}

/// Type of the tracking table's `applied_at`: a point in time, whatever
/// the session's time zone.
pub const instant_type = "timestamptz";

/// `to_regclass` finds the table the way an unqualified name in a
/// statement does, so this checks the table that `select` and `insert`
/// use. It reads `table` as SQL would read it unquoted, which is the same
/// for a lowercase name.
pub fn trackingCurrent(w: *Writer, table: []const u8, columns: []const []const u8) Writer.Error!void {
    try w.writeAll("SELECT 1 FROM pg_attribute WHERE attrelid = to_regclass(");
    try literal(w, .{ .string = table });
    try w.writeAll(") AND NOT attisdropped AND attname IN (");
    for (columns, 0..) |c, i| {
        if (i > 0) try w.writeAll(", ");
        try literal(w, .{ .string = c });
    }
    try w.print(") HAVING count(*) = {d}", .{columns.len});
}

/// Whole seconds since 1970 of a `timestamptz` column, null staying null.
pub fn epochSeconds(w: *Writer, column: []const u8) Writer.Error!void {
    try w.writeAll("floor(extract(epoch FROM ");
    try identifier(w, column);
    try w.writeAll("))::bigint");
}

/// `search_path` holds only the schema, so tables are neither found nor
/// created anywhere else.
pub fn schema(w: *Writer, s: root.Schema) Writer.Error!void {
    switch (s) {
        .exists => |name| {
            try w.writeAll("SELECT 1 FROM pg_namespace WHERE nspname = ");
            try literal(w, .{ .string = name });
        },
        .use => |name| {
            try w.writeAll("SET search_path TO ");
            try identifier(w, name);
        },
    }
}

pub fn databaseExists(w: *Writer, name: []const u8) Writer.Error!void {
    try w.writeAll("SELECT 1 FROM pg_database WHERE datname = ");
    try literal(w, .{ .string = name });
}

/// The protection mark is a custom setting on the database, which
/// PostgreSQL keeps in its catalog, so it survives everything short of
/// dropping the database and never depends on ffmig's own tables.
const protected_setting = "ffmig.protected";

pub fn setProtected(w: *Writer, name: []const u8, on: bool) Writer.Error!void {
    try w.writeAll("ALTER DATABASE ");
    try identifier(w, name);
    try w.writeAll(if (on) " SET " ++ protected_setting ++ " = on" else " RESET " ++ protected_setting);
}

pub fn databaseProtected(w: *Writer, name: []const u8) Writer.Error!void {
    try w.writeAll(
        \\SELECT 1 FROM pg_db_role_setting s JOIN pg_database d ON d.oid = s.setdatabase
        \\WHERE s.setrole = 0 AND '
    ++ protected_setting ++ "=on' = ANY (s.setconfig) AND d.datname = ");
    try literal(w, .{ .string = name });
}
