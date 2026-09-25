const std = @import("std");
const pg_dump = @import("ffmig").db.pg_dump;

const testing = std.testing;

test "splitPassword keeps the password out of the url" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_]struct { []const u8, []const u8, ?[]const u8 }{
        .{ "postgres://app:s%40cret@db:5432/app?sslmode=require", "postgres://app@db:5432/app?sslmode=require", "s@cret" },
        .{ "postgresql://app:@db/app", "postgresql://app@db/app", "" },
        .{ "postgres://app@db/app", "postgres://app@db/app", null },
        .{ "postgres://db/app?options=a:b@c", "postgres://db/app?options=a:b@c", null },
        .{ "postgres:///app?host=/tmp", "postgres:///app?host=/tmp", null },
        .{ "postgres://u:p:q@[::1]:5432/app", "postgres://u@[::1]:5432/app", "p:q" },
    };
    for (cases) |c| {
        const split = try pg_dump.splitPassword(a, c[0]);
        try testing.expectEqualStrings(c[1], split.url);
        if (c[2]) |p| try testing.expectEqualStrings(p, split.password.?) else try testing.expectEqual(null, split.password);
    }
}

test "command dumps the schema only, and one schema when set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cmd = try pg_dump.command(arena.allocator(), "pg_dump", "postgres://u:pw@h/app", "billing");
    const expected = [_][]const u8{ "pg_dump", "--schema-only", "--no-owner", "--no-privileges", "--schema=billing", "--dbname=postgres://u@h/app" };
    try testing.expectEqual(expected.len, cmd.argv.len);
    for (expected, cmd.argv) |e, a| try testing.expectEqualStrings(e, a);
    try testing.expectEqualStrings("pw", cmd.password.?);
}

test "clean replaces the header and settings, and drops what differs between runs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const raw =
        \\--
        \\-- PostgreSQL database dump
        \\--
        \\
        \\\restrict GiGRa4bjlfC0YdxTejklm4bK4Dsh
        \\
        \\-- Dumped from database version 18.6
        \\-- Dumped by pg_dump version 18.6
        \\
        \\SET statement_timeout = 0;
        \\SET transaction_timeout = 0;
        \\SELECT pg_catalog.set_config('search_path', '', false);
        \\SET row_security = off;
        \\
        \\--
        \\-- Name: billing; Type: SCHEMA; Schema: -; Owner: -
        \\--
        \\
        \\CREATE SCHEMA billing;
        \\
        \\
        \\--
        \\-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
        \\--
        \\
        \\CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;
        \\
        \\
        \\--
        \\-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
        \\--
        \\
        \\COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';
        \\
        \\
        \\SET default_tablespace = '';
        \\
        \\--
        \\-- Name: users; Type: TABLE; Schema: public; Owner: -
        \\--
        \\
        \\CREATE TABLE public.users (
        \\    id bigint NOT NULL
        \\);
        \\
        \\
        \\--
        \\-- PostgreSQL database dump complete
        \\--
        \\
        \\\unrestrict GiGRa4bjlfC0YdxTejklm4bK4Dsh
        \\
        \\
    ;
    const expected = pg_dump.preamble ++
        \\
        \\--
        \\-- Name: billing; Type: SCHEMA; Schema: -; Owner: -
        \\--
        \\
        \\CREATE SCHEMA IF NOT EXISTS billing;
        \\
        \\
        \\--
        \\-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
        \\--
        \\
        \\CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;
        \\
        \\
        \\SET default_tablespace = '';
        \\
        \\--
        \\-- Name: users; Type: TABLE; Schema: public; Owner: -
        \\--
        \\
        \\CREATE TABLE public.users (
        \\    id bigint NOT NULL
        \\);
        \\
    ;
    try testing.expectEqualStrings(expected, try pg_dump.clean(arena.allocator(), raw));
    // An empty database: the preamble alone.
    try testing.expectEqualStrings(pg_dump.preamble, try pg_dump.clean(arena.allocator(), "--\n-- PostgreSQL database dump\n--\n\nSET x = 0;\n\n--\n-- PostgreSQL database dump complete\n--\n\n"));
}

test "versionMismatch" {
    try testing.expect(pg_dump.versionMismatch("pg_dump: error: aborting because of server version mismatch\npg_dump: detail: server version: 17.2; pg_dump version: 16.4\n"));
    try testing.expect(!pg_dump.versionMismatch("pg_dump: error: connection to server failed\n"));
}
