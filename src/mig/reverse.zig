//! Derives the operations to apply (`up`) and to undo (`down`) from a
//! migration. Inside `change`, `down` inverts each operation in reverse
//! order; `up` / `down` migrations pass through unchanged. Pure AST to AST.
//! See "Reversibility" in `docs/mig.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Diagnostic = @import("parser.zig").Diagnostic;

pub const Error = error{ Irreversible, OutOfMemory };

pub const Plan = struct { up: []const ast.Operation, down: []const ast.Operation };

/// On `error.Irreversible`, `diag` holds the message and the span of the
/// first operation that cannot be undone. The returned operations share
/// their payloads with `m`.
pub fn plan(arena: Allocator, m: ast.Migration, diag: *Diagnostic) Error!Plan {
    switch (m.body) {
        .up_down => |b| return .{ .up = b.up, .down = b.down },
        .change => |ops| {
            const down = try arena.alloc(ast.Operation, ops.len);
            for (ops, 0..) |op, i| {
                down[ops.len - 1 - i] = .{ .kind = try invert(op, diag), .span = op.span };
            }
            return .{ .up = ops, .down = down };
        },
    }
}

fn invert(op: ast.Operation, diag: *Diagnostic) Error!ast.Operation.Kind {
    return switch (op.kind) {
        .create_table => |o| .{ .drop_table = .{ .table = o.table, .id = o.id, .columns = o.columns } },
        .drop_table => |o| .{ .create_table = .{
            .table = o.table,
            .id = o.id,
            .columns = o.columns orelse return irreversible(op, diag, "drop_table without a column block"),
        } },
        .add_column => |o| .{ .remove_column = .{ .table = o.table, .name = o.column.name, .column = o.column } },
        .remove_column => |o| .{ .add_column = .{
            .table = o.table,
            .column = o.column orelse return irreversible(op, diag, "remove_column without a type"),
        } },
        .rename_column => |o| .{ .rename_column = .{ .table = o.table, .from = o.to, .to = o.from } },
        .add_index => |o| .{ .remove_index = .{ .table = o.table, .column = o.column, .unique = o.unique, .name = o.name } },
        .remove_index => |o| .{ .add_index = .{
            .table = o.table,
            .column = o.column orelse return irreversible(op, diag, "remove_index without a column"),
            .unique = o.unique,
            .name = o.name,
        } },
        .rename_table => |o| .{ .rename_table = .{ .from = o.to, .to = o.from } },
        .change_column => |o| .{ .change_column = .{
            .table = o.table,
            .column = o.column,
            .to = o.from orelse return irreversible(op, diag, "change_column without 'from:'"),
            .from = o.to,
        } },
        // Filling the nulls is not undone.
        .change_column_null => |o| .{ .change_column_null = .{ .table = o.table, .column = o.column, .null = !o.null } },
        .change_column_default => |o| .{ .change_column_default = .{
            .table = o.table,
            .column = o.column,
            .from = o.to,
            .to = o.from orelse return irreversible(op, diag, "change_column_default without 'from:'"),
        } },
        .rename_index => |o| .{ .rename_index = .{ .table = o.table, .from = o.to, .to = o.from } },
        .add_foreign_key => |o| .{ .remove_foreign_key = .{
            .table = o.table,
            .to_table = o.foreign_key.table,
            .column = o.column,
            .on_delete = o.foreign_key.on_delete,
            .name = o.name,
        } },
        .remove_foreign_key => |o| .{ .add_foreign_key = .{
            .table = o.table,
            .column = o.column orelse return irreversible(op, diag, "remove_foreign_key without :to_table or 'column:'"),
            .foreign_key = .{
                .table = o.to_table orelse return irreversible(op, diag, "remove_foreign_key without :to_table or 'column:'"),
                .on_delete = o.on_delete,
            },
            .name = o.name,
        } },
        // Lowering rejects it in `change`.
        .execute => return irreversible(op, diag, "execute"),
    };
}

fn irreversible(op: ast.Operation, diag: *Diagnostic, comptime what: []const u8) Error {
    diag.* = .{ .span = op.span, .message = what ++ " is irreversible" };
    return error.Irreversible;
}
