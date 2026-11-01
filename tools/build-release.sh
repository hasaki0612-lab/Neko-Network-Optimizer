#!/usr/bin/env bash
# Builds dist/neko-v<VERSION>.tar.gz (+ .sha256 and SHA256SUMS) for a GitHub
# Release. Upload all three files as release assets; install.sh downloads the
# tarball and refuses to install it unless the SHA256 matches.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ver=$(tr -d ' \r\n' <"$root/VERSION")
ver="v${ver#v}"
dist="$root/dist"
name="neko-${ver}.tar.gz"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

# Refuse to ship CRLF line endings (they break bash on Linux). -U keeps Git for
# Windows' grep from hiding the CR the way it does in text mode.
if grep -rlIU $'\r' "$root"/{neko.sh,install.sh,README.md,lib,core,engine,modules,data,docs} 2>/dev/null; then
  echo "error: files above contain CRLF line endings" >&2
  exit 1
fi

mkdir -p "$stage/neko" "$dist"
cp -R "$root"/{neko.sh,install.sh,VERSION,README.md,lib,core,engine,modules,data,docs} "$stage/neko/"
find "$stage/neko" -type f -name '*.sh' -exec chmod 755 {} +
tar -C "$stage" --owner=0 --group=0 --numeric-owner -czf "$dist/$name" neko
(cd "$dist" && sha256sum "$name" >"$name.sha256" && sha256sum "$name" >SHA256SUMS)
echo "built $dist/$name"
cat "$dist/$name.sha256"
