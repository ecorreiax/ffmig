//! Syntax tree produced by the parser: generic calls, no knowledge of which
//! operations exist. See "Grammar" in `MIG.md`. Lowering turns this
//! into the typed AST.

const Span = @import("token.zig").Span;

pub const File = struct {
    /// Migration name, e.g. `CreateUsersProfile`.
    name: []const u8,
    name_span: Span,
    /// Arguments after the name, e.g. `transaction: false`. The grammar
    /// allows positional ones too; lowering rejects them.
    args: []Value,
    options: []Option,
    /// `change` / `up` / `down`, in source order. Lowering validates the combination.
    sections: []Section,
    span: Span,
};

pub const Section = struct {
    kind: Kind,
    kind_span: Span,
    calls: []Call,
    span: Span,

    pub const Kind = enum { change, up, down };
};

pub const Call = struct {
    name: []const u8,
    name_span: Span,
    /// Positional arguments.
    args: []Value,
    /// Labeled arguments, in source order. Duplicates are kept; lowering rejects them.
    options: []Option,
    /// `null` when there is no block, an empty slice for `{}`.
    block: ?[]Call,
    span: Span,
};

pub const Option = struct {
    key: []const u8,
    key_span: Span,
    value: Value,
};

pub const Value = struct {
    kind: Kind,
    span: Span,

    pub const Kind = union(enum) {
        symbol: []const u8,
        /// Unescaped. A slice of the source unless it had escapes.
        string: []const u8,
        integer: i64,
        boolean: bool,
        nil,
    };
};
