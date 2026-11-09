#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname -m)" != arm64 ]]; then
    printf '%s\n' 'QuietExtract requires an Apple silicon Mac.' >&2
    exit 1
fi

archive_sha256=b6f17920b4240940461dac8ef4009891881ac44d2a5ead625ede2ec8472185dd
engine_sha256=56cf8eb2fdc6f9c0ac5d7a3cd238505814ac8ed6b88a7c64a7e3256036252c60
engine=.build/7zz
mkdir -p .build

if [[ -x "$engine" ]] && printf '%s  %s\n' "$engine_sha256" "$engine" | shasum -a 256 -c --status; then
    exit 0
fi

work="$(mktemp -d .build/7zip.XXXXXX)"
trap 'rm -rf "$work"' EXIT
archive="$work/7z2606-mac.tar.xz"
curl --fail --location --retry 2 --output "$archive" \
    'https://github.com/ip7z/7zip/releases/download/26.06/7z2606-mac.tar.xz'
printf '%s  %s\n' "$archive_sha256" "$archive" | shasum -a 256 -c
tar -xf "$archive" -C "$work" 7zz
printf '%s  %s\n' "$engine_sha256" "$work/7zz" | shasum -a 256 -c
chmod 755 "$work/7zz"
mv -f "$work/7zz" "$engine"
