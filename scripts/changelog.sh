#!/bin/sh
# Prints the section of CHANGELOG.md for a version, without its heading:
# the release notes.
#
#   scripts/changelog.sh 0.1.0
set -eu

version=$1
root=$(cd "$(dirname "$0")/.." && pwd)
notes=$(awk -v heading="## $version" '
    $0 == heading { found = 1; next }
    found && /^## / { exit }
    found { print }
' "$root/CHANGELOG.md")
if [ -z "$(printf '%s' "$notes" | tr -d '[:space:]')" ]; then
    echo "changelog: CHANGELOG.md has no section '## $version'" >&2
    exit 1
fi
printf '%s\n' "$notes" | sed -e '/./,$!d'
