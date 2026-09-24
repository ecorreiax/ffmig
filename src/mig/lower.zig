//! Lowering: turns the parser's generic call tree (`syntax.zig`) into the
//! typed `ast.Migration`, checking the migration form, operations,
//! arguments, options, column types and defaults. See "Migration forms"
//! onward in `docs/mig.md`. This is the only module that reads `syntax`.
//! Stops at the first error.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const syntax = @import("syntax.zig");
const parser = @import("parser.zig");
const Span = @import("token.zig").Span;
const Diagnostic = parser.Diagnostic;

pub const Error = error{ InvalidMigration, OutOfMemory };

/// Everything returned, including `diag.message`, is allocated in `arena`;
/// names are slices of the source `file` was parsed from.
pub fn lower(arena: Allocator, file: syntax.File, diag: *Diagnostic) Error!ast.Migration {
    var l: Lowerer = .{ .arena = arena, .diag = diag };
    const transaction = try l.lowerTransaction(file);
    return .{ .name = file.name, .transaction = transaction, .body = try l.lowerBody(file.sections) };
}

/// The operations a section may hold. `add_reference` and
/// `remove_reference` lower to `add_column` and `remove_column`.
/// `execute` is only allowed in `up` and `down`.
const OpName = enum {
    create_table,
    drop_table,
    rename_table,
    add_column,
    remove_column,
    rename_column,
    change_column,
    change_column_null,
    change_column_default,
    add_index,
    remove_index,
    rename_index,
    add_reference,
    remove_reference,
    add_foreign_key,
    remove_foreign_key,
    execute,
};

const migration_options = [_][]const u8{"transaction"};
const column_options = [_][]const u8{ "null", "default", "limit", "precision", "scale" };
const index_options = [_][]const u8{ "unique", "name" };
const reference_options = [_][]const u8{ "type", "to", "null", "foreign_key", "index", "on_delete" };
const foreign_key_options = [_][]const u8{ "column", "on_delete", "name" };
const change_column_options = [_][]const u8{ "limit", "precision", "scale", "from", "from_limit", "from_precision", "from_scale" };

const Lowerer = struct {
    arena: Allocator,
    diag: *Diagnostic,

    /// The options after the migration name: only `transaction:`.
    fn lowerTransaction(l: *Lowerer, file: syntax.File) Error!bool {
        if (file.args.len > 0) {
            return l.fail(file.args[0].span, "migration takes only options, such as 'transaction: false'", .{});
        }
        try l.checkOptionsOf("migration", file.options, &migration_options);
        return try l.optionBool(file.options, "transaction") orelse true;
    }

    /// Exactly `change`, or exactly one `up` plus one `down`, in either order.
    fn lowerBody(l: *Lowerer, sections: []const syntax.Section) Error!ast.Body {
        var seen: std.EnumArray(syntax.Section.Kind, ?*const syntax.Section) = .initFill(null);
        for (sections) |*s| {
            if (seen.get(s.kind) != null) return l.fail(s.kind_span, "'{t}' block defined twice", .{s.kind});
            const conflict = switch (s.kind) {
                .change => seen.get(.up) orelse seen.get(.down),
                .up, .down => seen.get(.change),
            };
            if (conflict) |c| {
                const other = if (s.kind == .change) c.kind else s.kind;
                return l.fail(s.kind_span, "migration has both 'change' and '{t}'", .{other});
            }
            seen.set(s.kind, s);
        }

        if (seen.get(.change)) |change| return .{ .change = try l.lowerOperations(change) };
        // The parser guarantees at least one section.
        const up = seen.get(.up) orelse return l.fail(seen.get(.down).?.kind_span, "missing 'up' block", .{});
        const down = seen.get(.down) orelse return l.fail(up.kind_span, "missing 'down' block", .{});
        return .{ .up_down = .{
            .up = try l.lowerOperations(up),
            .down = try l.lowerOperations(down),
        } };
    }

    fn lowerOperations(l: *Lowerer, section: *const syntax.Section) Error![]ast.Operation {
        const ops = try l.arena.alloc(ast.Operation, section.calls.len);
        for (section.calls, ops) |call, *op| op.* = try l.lowerOperation(call, section.kind);
        return ops;
    }

    /// `section` is the kind of section `call` is in.
    fn lowerOperation(l: *Lowerer, call: syntax.Call, section: syntax.Section.Kind) Error!ast.Operation {
        const name = std.meta.stringToEnum(OpName, call.name) orelse
            return l.fail(call.name_span, "unknown operation '{s}'", .{call.name});
        // ffmig cannot undo SQL it does not model.
        if (name == .execute and section == .change) {
            return l.fail(call.name_span, "execute is not allowed in 'change'; write 'up' and 'down'", .{});
        }
        const kind: ast.Operation.Kind = switch (name) {
            .create_table => .{ .create_table = try l.lowerCreateTable(call) },
            .drop_table => .{ .drop_table = try l.lowerDropTable(call) },
            .rename_table => .{ .rename_table = try l.lowerRenameTable(call) },
            .add_column => .{ .add_column = try l.lowerAddColumn(call) },
            .remove_column => .{ .remove_column = try l.lowerRemoveColumn(call) },
            .rename_column => .{ .rename_column = try l.lowerRenameColumn(call) },
            .change_column => .{ .change_column = try l.lowerChangeColumn(call) },
            .change_column_null => .{ .change_column_null = try l.lowerChangeColumnNull(call) },
            .change_column_default => .{ .change_column_default = try l.lowerChangeColumnDefault(call) },
            .add_index => .{ .add_index = try l.lowerAddIndex(call) },
            .remove_index => .{ .remove_index = try l.lowerRemoveIndex(call) },
            .rename_index => .{ .rename_index = try l.lowerRenameIndex(call) },
            .add_reference => .{ .add_column = try l.lowerAddReference(call) },
            .remove_reference => .{ .remove_column = try l.lowerRemoveReference(call) },
            .add_foreign_key => .{ .add_foreign_key = try l.lowerAddForeignKey(call) },
            .remove_foreign_key => .{ .remove_foreign_key = try l.lowerRemoveForeignKey(call) },
            .execute => .{ .execute = try l.lowerExecute(call) },
        };
        return .{ .kind = kind, .span = call.span };
    }

    fn lowerCreateTable(l: *Lowerer, call: syntax.Call) Error!ast.CreateTable {
        try l.expectArgCount(call, 1, 1, ":table");
        const table = try l.expectSymbol(call, 0, ":table");
        try l.checkOptions(call, &.{"id"});
        const id = try l.optionId(call.options);
        const block = call.block orelse return l.fail(call.name_span, "create_table needs a block of columns", .{});
        return .{ .table = table, .id = id, .columns = try l.lowerColumns(table, id, block) };
    }

    fn lowerDropTable(l: *Lowerer, call: syntax.Call) Error!ast.DropTable {
        try l.expectArgCount(call, 1, 1, ":table");
        const table = try l.expectSymbol(call, 0, ":table");
        try l.checkOptions(call, &.{"id"});
        const id = try l.optionId(call.options);
        const columns = if (call.block) |block| try l.lowerColumns(table, id, block) else null;
        return .{ .table = table, .id = id, .columns = columns };
    }

    fn lowerRenameTable(l: *Lowerer, call: syntax.Call) Error!ast.RenameTable {
        try l.expectArgCount(call, 2, 2, ":from, :to");
        const from = try l.expectSymbol(call, 0, ":from");
        const to = try l.expectSymbol(call, 1, ":to");
        try l.checkOptions(call, &.{});
        try l.expectNoBlock(call);
        return .{ .from = from, .to = to };
    }

    fn lowerAddColumn(l: *Lowerer, call: syntax.Call) Error!ast.AddColumn {
        try l.expectArgCount(call, 3, 3, ":table, :column, :type");
        const table = try l.expectSymbol(call, 0, ":table");
        const name = try l.expectSymbol(call, 1, ":column");
        const column_type = try l.expectColumnType(call, 2);
        try l.checkOptions(call, &column_options);
        try l.expectNoBlock(call);
        return .{ .table = table, .column = try l.lowerColumn(name, column_type, call.options, call.span) };
    }

    fn lowerRemoveColumn(l: *Lowerer, call: syntax.Call) Error!ast.RemoveColumn {
        try l.expectArgCount(call, 2, 3, ":table, :column [, :type]");
        const table = try l.expectSymbol(call, 0, ":table");
        const name = try l.expectSymbol(call, 1, ":column");
        try l.expectNoBlock(call);
        if (call.args.len == 2) {
            if (call.options.len > 0) {
                return l.fail(labelSpan(call.options[0]), "remove_column takes options only with a :type", .{});
            }
            return .{ .table = table, .name = name, .column = null };
        }
        const column_type = try l.expectColumnType(call, 2);
        try l.checkOptions(call, &column_options);
        return .{ .table = table, .name = name, .column = try l.lowerColumn(name, column_type, call.options, call.span) };
    }

    fn lowerRenameColumn(l: *Lowerer, call: syntax.Call) Error!ast.RenameColumn {
        try l.expectArgCount(call, 3, 3, ":table, :from, :to");
        const table = try l.expectSymbol(call, 0, ":table");
        const from = try l.expectSymbol(call, 1, ":from");
        const to = try l.expectSymbol(call, 2, ":to");
        try l.checkOptions(call, &.{});
        try l.expectNoBlock(call);
        return .{ .table = table, .from = from, .to = to };
    }

    /// `change_column :table, :column, :type`, with the new type's size
    /// options, and `from:` plus `from_limit:`, ... for the old type.
    fn lowerChangeColumn(l: *Lowerer, call: syntax.Call) Error!ast.ChangeColumn {
        try l.expectArgCount(call, 3, 3, ":table, :column, :type");
        const table = try l.expectSymbol(call, 0, ":table");
        const column = try l.expectSymbol(call, 1, ":column");
        const column_type = try l.expectColumnType(call, 2);
        try l.checkOptions(call, &change_column_options);
        try l.expectNoBlock(call);
        const to = try l.lowerSizedType(column_type, call.options, "");
        const opt = findOption(call.options, "from") orelse {
            for ([_][]const u8{ "from_limit", "from_precision", "from_scale" }) |key| {
                if (findOption(call.options, key)) |o| return l.fail(labelSpan(o), "'{s}:' needs 'from:'", .{key});
            }
            return .{ .table = table, .column = column, .to = to, .from = null };
        };
        const from_type = switch (opt.value.kind) {
            .symbol => |s| std.meta.stringToEnum(ast.ColumnType, s) orelse
                return l.fail(opt.value.span, "unknown column type '{s}'", .{s}),
            else => return l.fail(opt.value.span, "'from:' must be a column type such as :string", .{}),
        };
        return .{ .table = table, .column = column, .to = to, .from = try l.lowerSizedType(from_type, call.options, "from_") };
    }

    /// `change_column_null :table, :column, true/false`, with `default:`
    /// to fill the nulls before setting false.
    fn lowerChangeColumnNull(l: *Lowerer, call: syntax.Call) Error!ast.ChangeColumnNull {
        try l.expectArgCount(call, 3, 3, ":table, :column, true/false");
        const table = try l.expectSymbol(call, 0, ":table");
        const column = try l.expectSymbol(call, 1, ":column");
        const value = call.args[2];
        const allow_null = switch (value.kind) {
            .boolean => |b| b,
            else => return l.fail(value.span, "change_column_null expects true or false, found {s}", .{describe(value)}),
        };
        try l.checkOptions(call, &.{"default"});
        try l.expectNoBlock(call);
        var result: ast.ChangeColumnNull = .{ .table = table, .column = column, .null = allow_null };
        if (findOption(call.options, "default")) |opt| {
            if (allow_null) return l.fail(labelSpan(opt), "change_column_null takes 'default:' only with false", .{});
            if (opt.value.kind == .nil) return l.fail(opt.value.span, "change_column_null cannot fill nulls with nil", .{});
            result.default = try l.lowerUntypedDefault(opt.value);
        }
        return result;
    }

    /// `change_column_default :table, :column, from: x, to: y`; `from:`
    /// is optional.
    fn lowerChangeColumnDefault(l: *Lowerer, call: syntax.Call) Error!ast.ChangeColumnDefault {
        try l.expectArgCount(call, 2, 2, ":table, :column");
        const table = try l.expectSymbol(call, 0, ":table");
        const column = try l.expectSymbol(call, 1, ":column");
        try l.checkOptions(call, &.{ "from", "to" });
        try l.expectNoBlock(call);
        const to = findOption(call.options, "to") orelse
            return l.fail(call.name_span, "change_column_default needs 'to:'", .{});
        const from = if (findOption(call.options, "from")) |opt| try l.lowerUntypedDefault(opt.value) else null;
        return .{ .table = table, .column = column, .from = from, .to = try l.lowerUntypedDefault(to.value) };
    }

    fn lowerAddIndex(l: *Lowerer, call: syntax.Call) Error!ast.AddIndex {
        try l.expectArgCount(call, 2, 2, ":table, :column");
        const table = try l.expectSymbol(call, 0, ":table");
        const column = try l.expectSymbol(call, 1, ":column");
        try l.checkOptions(call, &index_options);
        try l.expectNoBlock(call);
        return .{
            .table = table,
            .column = column,
            .unique = try l.optionBool(call.options, "unique") orelse false,
            .name = try l.optionString(call.options, "name"),
        };
    }

    fn lowerRemoveIndex(l: *Lowerer, call: syntax.Call) Error!ast.RemoveIndex {
        try l.expectArgCount(call, 1, 2, ":table [, :column]");
        const table = try l.expectSymbol(call, 0, ":table");
        const column = if (call.args.len == 2) try l.expectSymbol(call, 1, ":column") else null;
        try l.checkOptions(call, &index_options);
        try l.expectNoBlock(call);
        const name = try l.optionString(call.options, "name");
        if (column == null and name == null) {
            return l.fail(call.name_span, "remove_index needs a column or 'name:'", .{});
        }
        return .{
            .table = table,
            .column = column,
            .unique = try l.optionBool(call.options, "unique") orelse false,
            .name = name,
        };
    }

    /// `rename_index :table, "from", "to"`. PostgreSQL does not need the
    /// table, but other databases name indexes per table.
    fn lowerRenameIndex(l: *Lowerer, call: syntax.Call) Error!ast.RenameIndex {
        try l.expectArgCount(call, 3, 3, ":table, \"from\", \"to\"");
        const table = try l.expectSymbol(call, 0, ":table");
        const from = try l.expectString(call, 1, "\"from\"");
        const to = try l.expectString(call, 2, "\"to\"");
        try l.checkOptions(call, &.{});
        try l.expectNoBlock(call);
        return .{ .table = table, .from = from, .to = to };
    }

    fn lowerAddForeignKey(l: *Lowerer, call: syntax.Call) Error!ast.AddForeignKey {
        try l.expectArgCount(call, 2, 2, ":table, :to_table");
        const table = try l.expectSymbol(call, 0, ":table");
        const to_table = try l.expectSymbol(call, 1, ":to_table");
        try l.checkOptions(call, &foreign_key_options);
        try l.expectNoBlock(call);
        return .{
            .table = table,
            .column = try l.optionSymbol(call.options, "column") orelse
                return l.fail(call.name_span, "add_foreign_key needs 'column:'", .{}),
            .foreign_key = .{ .table = to_table, .on_delete = try l.optionOnDelete(call.options) },
            .name = try l.optionString(call.options, "name"),
        };
    }

    fn lowerRemoveForeignKey(l: *Lowerer, call: syntax.Call) Error!ast.RemoveForeignKey {
        try l.expectArgCount(call, 1, 2, ":table [, :to_table]");
        const table = try l.expectSymbol(call, 0, ":table");
        const to_table = if (call.args.len == 2) try l.expectSymbol(call, 1, ":to_table") else null;
        try l.checkOptions(call, &foreign_key_options);
        try l.expectNoBlock(call);
        const column = try l.optionSymbol(call.options, "column");
        const name = try l.optionString(call.options, "name");
        if (column == null and name == null) {
            return l.fail(call.name_span, "remove_foreign_key needs 'column:' or 'name:'", .{});
        }
        return .{
            .table = table,
            .to_table = to_table,
            .column = column,
            .on_delete = try l.optionOnDelete(call.options),
            .name = name,
        };
    }

    fn lowerAddReference(l: *Lowerer, call: syntax.Call) Error!ast.AddColumn {
        const table, const column = try l.lowerReferenceOperation(call);
        return .{ .table = table, .column = column };
    }

    fn lowerRemoveReference(l: *Lowerer, call: syntax.Call) Error!ast.RemoveColumn {
        const table, const column = try l.lowerReferenceOperation(call);
        return .{ .table = table, .name = column.name, .column = column };
    }

    /// `execute "sql"`, with an optional `dialect:`.
    fn lowerExecute(l: *Lowerer, call: syntax.Call) Error!ast.Execute {
        try l.expectArgCount(call, 1, 1, "\"sql\"");
        const text = try l.expectString(call, 0, "\"sql\"");
        if (std.mem.indexOfNone(u8, text, " \t\r\n;") == null) return l.fail(call.args[0].span, "execute has no SQL", .{});
        try l.checkOptions(call, &.{"dialect"});
        try l.expectNoBlock(call);
        return .{ .sql = text, .dialect = try l.optionDialect(call.options) };
    }

    /// `add_reference` / `remove_reference :table, :name, opts`.
    fn lowerReferenceOperation(l: *Lowerer, call: syntax.Call) Error!struct { []const u8, ast.Column } {
        try l.expectArgCount(call, 2, 2, ":table, :name");
        const table = try l.expectSymbol(call, 0, ":table");
        const name = try l.expectSymbol(call, 1, ":name");
        try l.checkOptions(call, &reference_options);
        try l.expectNoBlock(call);
        return .{ table, try l.lowerReference(name, call.args[1].span, call.options, call.span) };
    }

    /// The statements of a `create_table` / `drop_table` block: `<type> :name, opts`,
    /// `references :name, opts` or `timestamps`.
    fn lowerColumns(l: *Lowerer, table: []const u8, id: ast.IdKind, calls: []const syntax.Call) Error![]ast.Column {
        var columns: std.ArrayList(ast.Column) = .empty;
        for (calls) |call| {
            if (std.mem.eql(u8, call.name, "timestamps")) {
                if (call.args.len > 0 or call.options.len > 0) {
                    return l.fail(call.name_span, "timestamps takes no arguments", .{});
                }
                try l.expectNoBlock(call);
                for ([_][]const u8{ "created_at", "updated_at" }) |name| {
                    const column: ast.Column = .{ .name = name, .type = .datetime, .null = false, .span = call.span };
                    try l.appendColumn(&columns, table, id, column, call.name_span);
                }
                continue;
            }

            if (std.mem.eql(u8, call.name, "references")) {
                try l.expectArgCount(call, 1, 1, ":name");
                const name = try l.expectSymbol(call, 0, ":name");
                try l.checkOptions(call, &reference_options);
                try l.expectNoBlock(call);
                const column = try l.lowerReference(name, call.args[0].span, call.options, call.span);
                try l.appendColumn(&columns, table, id, column, call.args[0].span);
                continue;
            }

            const column_type = std.meta.stringToEnum(ast.ColumnType, call.name) orelse {
                if (std.meta.stringToEnum(OpName, call.name) != null) {
                    return l.fail(call.name_span, "{s} is not allowed inside a table block", .{call.name});
                }
                return l.fail(call.name_span, "unknown column type '{s}'", .{call.name});
            };
            try l.expectArgCount(call, 1, 1, ":name");
            const name = try l.expectSymbol(call, 0, ":name");
            try l.checkOptions(call, &column_options);
            try l.expectNoBlock(call);
            const column = try l.lowerColumn(name, column_type, call.options, call.span);
            try l.appendColumn(&columns, table, id, column, call.args[0].span);
        }
        return columns.toOwnedSlice(l.arena);
    }

    /// Appends `column`, rejecting a name already used in the table (or `id`
    /// when the table has a primary key). `span` is where to report it.
    fn appendColumn(
        l: *Lowerer,
        columns: *std.ArrayList(ast.Column),
        table: []const u8,
        id: ast.IdKind,
        column: ast.Column,
        span: Span,
    ) Error!void {
        var taken = id != .none and std.mem.eql(u8, column.name, "id");
        for (columns.items) |c| taken = taken or std.mem.eql(u8, c.name, column.name);
        if (taken) return l.fail(span, "column '{s}' defined twice in table '{s}'", .{ column.name, table });
        try columns.append(l.arena, column);
    }

    /// Column options, already checked for unknown and duplicate keys.
    fn lowerColumn(
        l: *Lowerer,
        name: []const u8,
        column_type: ast.ColumnType,
        options: []const syntax.Option,
        span: Span,
    ) Error!ast.Column {
        const sized = try l.lowerSizedType(column_type, options, "");
        var column: ast.Column = .{
            .name = name,
            .type = column_type,
            .limit = sized.limit,
            .precision = sized.precision,
            .scale = sized.scale,
            .span = span,
        };
        if (try l.optionBool(options, "null")) |n| column.null = n;
        if (findOption(options, "default")) |opt| column.default = try l.lowerDefault(opt.value, column);
        return column;
    }

    /// `column_type` with the size options `limit:`, `precision:` and
    /// `scale:`, each spelled with `prefix` in front (`from_limit:`).
    fn lowerSizedType(
        l: *Lowerer,
        column_type: ast.ColumnType,
        options: []const syntax.Option,
        comptime prefix: []const u8,
    ) Error!ast.SizedType {
        var sized: ast.SizedType = .{ .type = column_type };
        if (findOption(options, prefix ++ "limit")) |opt| {
            if (column_type != .string) return l.fail(labelSpan(opt), "'" ++ prefix ++ "limit:' is only allowed on string columns", .{});
            sized.limit = try l.integer(opt, u32, 1, std.math.maxInt(u32));
        }
        if (findOption(options, prefix ++ "precision")) |opt| {
            if (column_type != .decimal) return l.fail(labelSpan(opt), "'" ++ prefix ++ "precision:' is only allowed on decimal columns", .{});
            sized.precision = try l.integer(opt, u8, 1, 255);
        }
        if (findOption(options, prefix ++ "scale")) |opt| {
            if (column_type != .decimal) return l.fail(labelSpan(opt), "'" ++ prefix ++ "scale:' is only allowed on decimal columns", .{});
            const precision = sized.precision orelse return l.fail(labelSpan(opt), "'" ++ prefix ++ "scale:' needs '" ++ prefix ++ "precision:'", .{});
            sized.scale = try l.integer(opt, u8, 0, precision);
        }
        return sized;
    }

    /// The `<name>_id` column of a reference, from reference options already
    /// checked for unknown and duplicate keys. `name_span` is where `name` is.
    fn lowerReference(
        l: *Lowerer,
        name: []const u8,
        name_span: Span,
        options: []const syntax.Option,
        span: Span,
    ) Error!ast.Column {
        if (name.len > "_id".len and std.mem.endsWith(u8, name, "_id")) {
            return l.fail(name_span, "reference ':{s}' already ends in '_id'; write ':{s}'", .{ name, name[0 .. name.len - "_id".len] });
        }
        var column: ast.Column = .{
            .name = try std.mem.concat(l.arena, u8, &.{ name, "_id" }),
            .type = try l.optionReferenceType(options),
            .span = span,
        };
        if (try l.optionBool(options, "null")) |n| column.null = n;

        var reference: ast.Reference = .{
            .foreign_key = null,
            .index = try l.optionReferenceIndex(options),
        };
        if (try l.optionBool(options, "foreign_key") orelse true) {
            var foreign_key: ast.ForeignKey = .{ .table = undefined };
            if (findOption(options, "to")) |opt| {
                foreign_key.table = switch (opt.value.kind) {
                    .symbol => |s| s,
                    else => return l.fail(opt.value.span, "'to:' must be a symbol", .{}),
                };
            } else foreign_key.table = try tableName(l.arena, name);
            foreign_key.on_delete = try l.optionOnDelete(options);
            if (foreign_key.on_delete == .nullify and !column.null) {
                const opt = findOption(options, "on_delete").?;
                return l.fail(opt.value.span, "on_delete: :nullify on non-null column '{s}'", .{column.name});
            }
            reference.foreign_key = foreign_key;
        } else for ([_][]const u8{ "to", "on_delete" }) |key| {
            if (findOption(options, key)) |opt| return l.fail(labelSpan(opt), "'{s}:' needs a foreign key", .{key});
        }
        column.reference = reference;
        return column;
    }

    /// The value of a `default:` on an operation that does not know the
    /// column's type (`change_column_default`, `change_column_null`): any
    /// literal, or a known named default. The database checks that it fits.
    fn lowerUntypedDefault(l: *Lowerer, value: syntax.Value) Error!ast.Default {
        return switch (value.kind) {
            .symbol => |s| .{ .named = std.meta.stringToEnum(ast.NamedDefault, s) orelse
                return l.fail(value.span, "unknown default ':{s}'", .{s}) },
            .nil => .{ .literal = .nil },
            .string => |s| .{ .literal = .{ .string = s } },
            .integer => |i| .{ .literal = .{ .integer = i } },
            .boolean => |b| .{ .literal = .{ .boolean = b } },
        };
    }

    /// `column` has every other option set, since `default: nil` depends on `null:`.
    fn lowerDefault(l: *Lowerer, value: syntax.Value, column: ast.Column) Error!ast.Default {
        const literal: ast.Literal = switch (value.kind) {
            .symbol => |s| {
                const named = std.meta.stringToEnum(ast.NamedDefault, s) orelse
                    return l.fail(value.span, "unknown default ':{s}'", .{s});
                if (!named.allows(column.type)) {
                    return l.fail(value.span, "default ':{t}' is not allowed on {t} column '{s}'", .{ named, column.type, column.name });
                }
                return .{ .named = named };
            },
            .nil => {
                if (!column.null) return l.fail(value.span, "default: nil on non-null column '{s}'", .{column.name});
                return .{ .literal = .nil };
            },
            .string => |s| .{ .string = s },
            .integer => |i| .{ .integer = i },
            .boolean => |b| .{ .boolean = b },
        };
        const allowed = switch (literal) {
            .string => switch (column.type) {
                .string, .text, .date, .datetime, .time, .uuid, .json => true,
                else => false,
            },
            .integer => switch (column.type) {
                .integer, .bigint, .float, .decimal => true,
                else => false,
            },
            .boolean => column.type == .boolean,
            .nil => unreachable,
        };
        if (!allowed) {
            return l.fail(value.span, "{t} default is not allowed on {t} column '{s}'", .{ literal, column.type, column.name });
        }
        return .{ .literal = literal };
    }

    fn expectArgCount(l: *Lowerer, call: syntax.Call, min: usize, max: usize, comptime usage: []const u8) Error!void {
        const got = call.args.len;
        if (got >= min and got <= max) return;
        if (min == max) {
            const plural = if (min == 1) "" else "s";
            return l.fail(call.name_span, "{s} expects {d} argument{s} (" ++ usage ++ "), got {d}", .{ call.name, min, plural, got });
        }
        return l.fail(call.name_span, "{s} expects {d} or {d} arguments (" ++ usage ++ "), got {d}", .{ call.name, min, max, got });
    }

    /// Positional argument `index`, which must exist, as a symbol. `what`
    /// names it in the error, e.g. `:table`.
    fn expectSymbol(l: *Lowerer, call: syntax.Call, index: usize, comptime what: []const u8) Error![]const u8 {
        const value = call.args[index];
        return switch (value.kind) {
            .symbol => |s| s,
            else => l.fail(value.span, "{s} expects " ++ what ++ " to be a symbol, found {s}", .{ call.name, describe(value) }),
        };
    }

    /// Positional argument `index`, which must exist, as a string.
    fn expectString(l: *Lowerer, call: syntax.Call, index: usize, comptime what: []const u8) Error![]const u8 {
        const value = call.args[index];
        return switch (value.kind) {
            .string => |s| s,
            else => l.fail(value.span, "{s} expects " ++ what ++ " to be a string, found {s}", .{ call.name, describe(value) }),
        };
    }

    fn expectColumnType(l: *Lowerer, call: syntax.Call, index: usize) Error!ast.ColumnType {
        const name = try l.expectSymbol(call, index, ":type");
        return std.meta.stringToEnum(ast.ColumnType, name) orelse
            l.fail(call.args[index].span, "unknown column type '{s}'", .{name});
    }

    fn expectNoBlock(l: *Lowerer, call: syntax.Call) Error!void {
        if (call.block != null) return l.fail(call.name_span, "{s} takes no block", .{call.name});
    }

    /// Rejects option keys not in `allowed`, and keys given more than once.
    fn checkOptions(l: *Lowerer, call: syntax.Call, allowed: []const []const u8) Error!void {
        return l.checkOptionsOf(call.name, call.options, allowed);
    }

    /// `checkOptions` for the `options` of `what`, which names it in errors.
    fn checkOptionsOf(l: *Lowerer, what: []const u8, options: []const syntax.Option, allowed: []const []const u8) Error!void {
        for (options, 0..) |opt, i| {
            for (allowed) |key| {
                if (std.mem.eql(u8, opt.key, key)) break;
            } else return l.fail(labelSpan(opt), "unknown option '{s}' for {s}", .{ opt.key, what });
            if (findOption(options[0..i], opt.key) != null) {
                return l.fail(labelSpan(opt), "option '{s}:' given twice", .{opt.key});
            }
        }
    }

    /// `id:` is `:bigint` (the default), `:uuid` or `false`.
    fn optionId(l: *Lowerer, options: []const syntax.Option) Error!ast.IdKind {
        const opt = findOption(options, "id") orelse return .bigint;
        switch (opt.value.kind) {
            .symbol => |s| {
                if (std.mem.eql(u8, s, "bigint")) return .bigint;
                if (std.mem.eql(u8, s, "uuid")) return .uuid;
            },
            .boolean => |b| if (!b) return .none,
            else => {},
        }
        return l.fail(opt.value.span, "'id:' must be :bigint, :uuid or false", .{});
    }

    /// A reference's `type:`: `:bigint` (the default) or `:uuid`.
    fn optionReferenceType(l: *Lowerer, options: []const syntax.Option) Error!ast.ColumnType {
        const opt = findOption(options, "type") orelse return .bigint;
        if (opt.value.kind == .symbol) {
            const s = opt.value.kind.symbol;
            if (std.mem.eql(u8, s, "bigint")) return .bigint;
            if (std.mem.eql(u8, s, "uuid")) return .uuid;
        }
        return l.fail(opt.value.span, "'type:' must be :bigint or :uuid", .{});
    }

    /// A reference's `index:`: `true` (the default), `false` or `:unique`.
    fn optionReferenceIndex(l: *Lowerer, options: []const syntax.Option) Error!ast.ReferenceIndex {
        const opt = findOption(options, "index") orelse return .plain;
        switch (opt.value.kind) {
            .boolean => |b| return if (b) .plain else .none,
            .symbol => |s| if (std.mem.eql(u8, s, "unique")) return .unique,
            else => {},
        }
        return l.fail(opt.value.span, "'index:' must be true, false or :unique", .{});
    }

    /// `on_delete:` of a foreign key: `:cascade`, `:nullify` or `:restrict`.
    fn optionOnDelete(l: *Lowerer, options: []const syntax.Option) Error!?ast.OnDelete {
        const opt = findOption(options, "on_delete") orelse return null;
        return switch (opt.value.kind) {
            .symbol => |s| std.meta.stringToEnum(ast.OnDelete, s),
            else => null,
        } orelse return l.fail(opt.value.span, "'on_delete:' must be :cascade, :nullify or :restrict", .{});
    }

    /// An `execute`'s `dialect:`, a symbol naming an `ast.Dialect`.
    fn optionDialect(l: *Lowerer, options: []const syntax.Option) Error!?ast.Dialect {
        const opt = findOption(options, "dialect") orelse return null;
        return switch (opt.value.kind) {
            .symbol => |s| std.meta.stringToEnum(ast.Dialect, s) orelse
                l.fail(opt.value.span, "unknown dialect ':{s}'", .{s}),
            else => l.fail(opt.value.span, "'dialect:' must be a symbol such as :postgres", .{}),
        };
    }

    fn optionBool(l: *Lowerer, options: []const syntax.Option, key: []const u8) Error!?bool {
        const opt = findOption(options, key) orelse return null;
        return switch (opt.value.kind) {
            .boolean => |b| b,
            else => l.fail(opt.value.span, "'{s}:' must be true or false", .{key}),
        };
    }

    fn optionSymbol(l: *Lowerer, options: []const syntax.Option, key: []const u8) Error!?[]const u8 {
        const opt = findOption(options, key) orelse return null;
        return switch (opt.value.kind) {
            .symbol => |s| s,
            else => l.fail(opt.value.span, "'{s}:' must be a symbol", .{key}),
        };
    }

    fn optionString(l: *Lowerer, options: []const syntax.Option, key: []const u8) Error!?[]const u8 {
        const opt = findOption(options, key) orelse return null;
        return switch (opt.value.kind) {
            .string => |s| s,
            else => l.fail(opt.value.span, "'{s}:' must be a string", .{key}),
        };
    }

    fn integer(l: *Lowerer, opt: syntax.Option, comptime T: type, min: T, max: T) Error!T {
        switch (opt.value.kind) {
            .integer => |i| if (i >= min and i <= max) return @intCast(i),
            else => {},
        }
        return l.fail(opt.value.span, "'{s}:' must be an integer from {d} to {d}", .{ opt.key, min, max });
    }

    fn fail(l: *Lowerer, span: Span, comptime fmt: []const u8, args: anytype) Error {
        const message = std.fmt.allocPrint(l.arena, fmt, args) catch |err| return err;
        l.diag.* = .{ .span = span, .message = message };
        return error.InvalidMigration;
    }
};

/// The table a reference named `name` points at without `to:`, by the
/// rules in "Table names" in `docs/mig.md`.
fn tableName(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    if (name.len >= 2 and name[name.len - 1] == 'y' and std.mem.indexOfScalar(u8, "aeiou", name[name.len - 2]) == null) {
        return std.mem.concat(arena, u8, &.{ name[0 .. name.len - 1], "ies" });
    }
    for ([_][]const u8{ "s", "x", "z", "ch", "sh" }) |ending| {
        if (std.mem.endsWith(u8, name, ending)) return std.mem.concat(arena, u8, &.{ name, "es" });
    }
    return std.mem.concat(arena, u8, &.{ name, "s" });
}

fn findOption(options: []const syntax.Option, key: []const u8) ?syntax.Option {
    for (options) |opt| {
        if (std.mem.eql(u8, opt.key, key)) return opt;
    }
    return null;
}

/// The option's key including its `:`, e.g. `uniq:`.
fn labelSpan(opt: syntax.Option) Span {
    return .{ .start = opt.key_span.start, .end = opt.key_span.end + 1 };
}

fn describe(value: syntax.Value) []const u8 {
    return switch (value.kind) {
        .symbol => "a symbol",
        .string => "a string",
        .integer => "an integer",
        .boolean => "a boolean",
        .nil => "nil",
    };
}
