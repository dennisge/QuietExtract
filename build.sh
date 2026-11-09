#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

./prepare-engine.sh
arch="$(uname -m)"
app=".build/QuietExtract.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" .build/modules
xcrun swiftc -swift-version 6 -warnings-as-errors -O -target "$arch-apple-macosx14.0" \
    -module-cache-path .build/modules -I Sources/CArchive Sources/QuietExtract/*.swift \
    -o "$app/Contents/MacOS/QuietExtract"

cp .build/7zz "$app/Contents/MacOS/7zz"
cp Vendor/7zip/License.txt "$app/Contents/Resources/7-Zip-LICENSE.txt"
codesign --force --sign - "$app/Contents/MacOS/7zz"
cp LICENSE "$app/Contents/Resources/QuietExtract-LICENSE.txt"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Sources/CArchive/COPYING "$app/Contents/Resources/libarchive-LICENSE.txt"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$PWD/$app"
