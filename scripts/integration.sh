#!/bin/sh
# Runs the integration tests against a throwaway PostgreSQL cluster.
#
# The cluster lives in a temporary directory, listens only on a Unix
# socket there (no TCP port), trusts every local connection, and is
# removed on exit. The tests find it through FFMIG_TEST_PGHOST.
#
# Needs initdb, pg_ctl and zig on PATH; the nix dev shell provides them.
set -eu

# /tmp rather than $TMPDIR: the socket path must fit in ~100 bytes.
dir=$(mktemp -d /tmp/ffmig-pg.XXXXXX)
cleanup() {
    pg_ctl -D "$dir/data" -m immediate stop >/dev/null 2>&1 || true
    rm -rf "$dir"
}
trap cleanup EXIT INT TERM

initdb -D "$dir/data" -U ffmig -A trust --no-sync >"$dir/initdb.log" 2>&1 ||
    { cat "$dir/initdb.log"; exit 1; }
pg_ctl -D "$dir/data" -l "$dir/postgres.log" -w \
    -o "-k $dir -c listen_addresses= -c fsync=off" start >/dev/null ||
    { cat "$dir/postgres.log"; exit 1; }

FFMIG_TEST_PGHOST=$dir ${ZIG:-zig} build integration --summary all "$@"
