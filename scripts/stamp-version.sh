#!/bin/sh
# Writes the release version into Sources/QualtiveCLICore/Version.swift.
set -eu

version="${1:?usage: stamp-version.sh <version>}"
case "$version" in
  *[!0-9A-Za-z.+-]*) echo "invalid version: $version" >&2; exit 1 ;;
esac

file="$(dirname "$0")/../Sources/QualtiveCLICore/Version.swift"
sed -i.bak "s/public static let current = \".*\"/public static let current = \"$version\"/" "$file"
rm -f "$file.bak"
grep -q "public static let current = \"$version\"" "$file"
