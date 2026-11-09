#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

./prepare-engine.sh
mkdir -p .build/modules
fixtures="$(mktemp -d "$PWD/.build/checks.XXXXXX")"
trap 'rm -rf "$fixtures"' EXIT
python3 - "$fixtures" <<'PY'
import io
import pathlib
import sys
import tarfile
import warnings
import zipfile

base = pathlib.Path(sys.argv[1])
payload = b"QuietExtract test\n"
(base / "payload.txt").write_bytes(payload)

def write_zip(name, entries):
    with zipfile.ZipFile(base / name, "w") as archive:
        for path in entries:
            archive.writestr(path, payload)

write_zip("unicode.zip", ["資料/測試.txt"])
write_zip("empty.zip", [])
write_zip("only.zip", ["payload.txt"])
(base / "only").symlink_to("payload.txt")
write_zip("traversal.zip", ["partial.txt", "../escape.txt"])
write_zip("absolute.zip", [str(base / "escape.txt")])
with warnings.catch_warnings():
    warnings.simplefilter("ignore", UserWarning)
    write_zip("duplicate.zip", ["payload.txt", "payload.txt"])
write_zip("corrupt.zip", ["payload.txt"])
broken = base / "corrupt.zip"
broken.write_bytes(broken.read_bytes().replace(payload, b"!" * len(payload), 1))
write_zip("quarantined.zip", ["payload.txt"])
with tarfile.open(base / "links.tar.gz", "w:gz") as archive:
    entry = tarfile.TarInfo("partial.txt")
    entry.size = len(payload)
    archive.addfile(entry, io.BytesIO(payload))
    link = tarfile.TarInfo("redirect")
    link.type = tarfile.SYMTYPE
    link.linkname = ".."
    archive.addfile(link)
PY
/usr/bin/zip -q -j -P test-fixture-password "$fixtures/password.zip" "$fixtures/payload.txt"
/usr/bin/bsdtar --format 7zip -cf "$fixtures/seven.7z" -C "$fixtures" payload.txt
COPYFILE_DISABLE=1 /usr/bin/bsdtar -czf "$fixtures/bundle.tar.gz" -C "$fixtures" payload.txt
for variant in stored compressed encrypted-filenames; do
    /usr/bin/uudecode -o "$fixtures/rar5-$variant.rar" "Tests/rar5-$variant.rar.uu"
done
/usr/bin/bsdtar -xOf "$fixtures/rar5-compressed.rar" test.bin > "$fixtures/expected-rar.bin"
printf '%s  %s\n' '588870a2dade35c2650fbb7898c9a9c7f21fce7c281198604e8d0c9737f2c375' \
    "$fixtures/expected-rar.bin" | shasum -a 256 -c -
xcrun swiftc -swift-version 6 -warnings-as-errors -O -module-cache-path .build/modules \
    -I Sources/CArchive Sources/QuietExtract/{ArchiveEngine,Extractor,Compressor}.swift Tests/ExtractionChecks.swift \
    -o .build/extraction-checks
.build/extraction-checks "$fixtures"
.build/7zz l -slt "$fixtures/aes.zip" | awk '/^Method = AES-256/ { found=1 } END { exit !found }'
printf '%s\n' 'PASS ZIP independently reports AES-256'
