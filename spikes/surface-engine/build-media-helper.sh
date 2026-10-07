#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
source_dir="$PWD/vendor/mediaremote-adapter"
framework="$PWD/.build/MediaRemoteAdapter.framework"
mkdir -p "$framework/Resources"
# Host architecture only. A candidate can use an explicit older SDK.
sdk_options=()
if [[ -n "${ONE_BUILD_SDK:-}" ]]; then
    sdk_options=(-isysroot "$ONE_BUILD_SDK")
fi
xcrun clang -dynamiclib -fobjc-arc -fvisibility=default -mmacosx-version-min=14.0 \
  "${sdk_options[@]}" \
  -I "$source_dir/include" -I "$source_dir/src" \
  "$source_dir"/src/adapter/*.m "$source_dir"/src/private/*.m "$source_dir"/src/utility/*.m \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name '@rpath/MediaRemoteAdapter.framework/MediaRemoteAdapter' \
  -o "$framework/MediaRemoteAdapter"
cat > "$framework/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.one.experimental.MediaRemoteAdapter</string>
<key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
codesign --force --sign - "$framework"
