#!/bin/sh
# Smoke test for a built ffmig binary: runs the command lifecycle against
# a throwaway PostgreSQL server that accepts only TLS connections, as
# managed databases do, so it checks that the binary finds a libpq built
# with TLS.
#
#   scripts/smoke.sh path/to/ffmig
#
# Needs initdb, pg_ctl and openssl on PATH, or PG_BIN set to the
# directory that holds initdb and pg_ctl. Listens on 127.0.0.1:$PORT
# (default 54329), over TCP only so that it runs on Windows too, and
# removes the server on exit.
set -eu

ffmig=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
port=${PORT:-54329}
bin=${PG_BIN:+$PG_BIN/}

dir=$(mktemp -d "${TMPDIR:-/tmp}/ffmig-smoke.XXXXXX")
cleanup() {
    "${bin}pg_ctl" -D "$dir/data" -m immediate stop >/dev/null 2>&1 || true
    rm -rf "$dir"
}
trap cleanup EXIT INT TERM

"${bin}initdb" -D "$dir/data" -U ffmig -A trust -E UTF8 --no-locale --no-sync >"$dir/initdb.log" 2>&1 ||
    { cat "$dir/initdb.log"; exit 1; }
# MSYS2 on Windows would turn /CN=localhost into a path.
MSYS2_ARG_CONV_EXCL='*' openssl req -new -x509 -days 1 -nodes -subj /CN=localhost \
    -keyout "$dir/data/server.key" -out "$dir/data/server.crt" >/dev/null 2>&1
chmod 600 "$dir/data/server.key"
# TLS only: plain connections are rejected.
printf 'hostssl all all 127.0.0.1/32 trust\nhostnossl all all 0.0.0.0/0 reject\n' >"$dir/data/pg_hba.conf"
"${bin}pg_ctl" -D "$dir/data" -l "$dir/postgres.log" -w \
    -o "-p $port -c listen_addresses=127.0.0.1 -c unix_socket_directories= -c ssl=on" start >/dev/null ||
    { cat "$dir/postgres.log"; exit 1; }

url="postgres://ffmig@127.0.0.1:$port/smoke?sslmode=require"
project="$dir/project"
mkdir "$project"
cd "$project"

run() {
    echo "\$ ffmig $*"
    "$ffmig" "$@"
}

run --version
run init --url "$url"
cat >migrations/20260101000000_create_users.mig <<'MIG'
migration CreateUsers {
  change {
    create_table :users, id: :uuid {
      string :email, null: false
      decimal :balance, precision: 10, scale: 2, default: 0.50
      timestamps time_zone: true
    }
    add_index :users, [:email, :created_at], unique: true
  }
}
MIG
run check
run create
run migrate
run status
run rollback
run migrate
run drop --force

if "$ffmig" status --url "postgres://ffmig@127.0.0.1:$port/postgres?sslmode=disable" >/dev/null 2>&1; then
    echo "smoke: the server accepted a connection without TLS" >&2
    exit 1
fi
echo "smoke: ok"
