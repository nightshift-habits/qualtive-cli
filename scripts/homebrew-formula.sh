#!/bin/sh
# Prints Formula/qualtive.rb for nightshift-habits/homebrew-tap from a release's SHA256SUMS.
set -eu

version="${1:?usage: homebrew-formula.sh <version> <SHA256SUMS>}"
sums="${2:?usage: homebrew-formula.sh <version> <SHA256SUMS>}"
base="https://github.com/nightshift-habits/qualtive-cli/releases/download/v$version"

sha() {
  sha="$(awk -v f="$1" '$2 == f || $2 == "*"f { print $1 }' "$sums")"
  if [ -z "$sha" ]; then
    echo "missing checksum for $1" >&2
    exit 1
  fi
  echo "$sha"
}

macos="qualtive-$version-macos-universal.zip"
linux_x86="qualtive-$version-linux-x86_64-musl.tar.gz"
linux_arm="qualtive-$version-linux-aarch64-musl.tar.gz"

cat <<EOF
class Qualtive < Formula
  desc "Command-line interface for Qualtive"
  homepage "https://github.com/nightshift-habits/qualtive-cli"
  version "$version"

  on_macos do
    url "$base/$macos"
    sha256 "$(sha "$macos")"
  end

  on_linux do
    on_intel do
      url "$base/$linux_x86"
      sha256 "$(sha "$linux_x86")"
    end
    on_arm do
      url "$base/$linux_arm"
      sha256 "$(sha "$linux_arm")"
    end
  end

  def install
    bin.install "qualtive"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/qualtive version")
  end
end
EOF
