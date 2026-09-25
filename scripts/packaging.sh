#!/bin/sh
# Writes the Homebrew formula and the Scoop manifest for a release, from
# the templates in packaging/ and the release's SHA256SUMS.
#
#   scripts/packaging.sh 0.1.0 dist/SHA256SUMS out
#
# writes out/Formula/ffmig.rb and out/bucket/ffmig.json.
set -eu

version=$1
sums=$2
out=$3
root=$(cd "$(dirname "$0")/.." && pwd)

sum() {
    hash=$(awk -v f="$1" '$2 == f || $2 == "*" f { print $1 }' "$sums")
    [ -n "$hash" ] || { echo "packaging: no checksum for $1 in $sums" >&2; exit 1; }
    echo "$hash"
}

mkdir -p "$out/Formula" "$out/bucket"
sed -e "s/@VERSION@/$version/g" \
    -e "s/@SHA256_MACOS_ARM64@/$(sum ffmig-macos-arm64.tar.gz)/" \
    -e "s/@SHA256_MACOS_AMD64@/$(sum ffmig-macos-amd64.tar.gz)/" \
    "$root/packaging/homebrew/ffmig.rb.in" >"$out/Formula/ffmig.rb"
sed -e "s/@VERSION@/$version/g" \
    -e "s/@SHA256_WINDOWS_AMD64@/$(sum ffmig-windows-amd64.zip)/" \
    "$root/packaging/scoop/ffmig.json.in" >"$out/bucket/ffmig.json"
