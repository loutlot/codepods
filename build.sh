#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p .build/ModuleCache
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" swift build -c release --disable-sandbox
app="$PWD/dist/Codepods.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
cp .build/release/Codepods "$app/Contents/MacOS/Codepods"
cp Assets/remote.png "$app/Contents/Resources/remote.png"
cp Assets/Codepods.icns "$app/Contents/Resources/Codepods.icns"
for localization in Localizations/*.lproj; do
    cp -R "$localization" "$app/Contents/Resources/"
done
codesign --force --sign - "$app"
echo "$app"
