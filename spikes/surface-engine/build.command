#!/bin/zsh
set -euo pipefail
trap 'print -u2 "Сборка ONE не завершена (код $?). См. ошибку выше."; if [[ -t 0 ]]; then read "?Нажмите Enter, чтобы закрыть окно…"; fi' ZERR
cd "${0:A:h}"
configuration=debug
bundle="$PWD/output/ONE Surface Spike.app"
build_options=(--disable-sandbox --build-system native -c "$configuration")
if (( $# > 0 )); then
    if [[ $# != 2 || "$1" != --release-candidate || ! -f "$2/SDKSettings.plist" ]]; then
        print -u2 "Использование: build.command [--release-candidate /полный/путь/MacOSX.sdk]"
        exit 1
    fi
    export ONE_BUILD_SDK="${2:A}"
    sdk_version="$(plutil -extract Version raw "$ONE_BUILD_SDK/SDKSettings.plist")"
    configuration=release
    bundle="$PWD/output/ONE Release Candidate.app"
    build_options=(--disable-sandbox --build-system native -c "$configuration"
        --scratch-path .build-consumer --sdk "$ONE_BUILD_SDK"
        -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$sdk_version")
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# Compile the owner's layered icon on every build; do not keep stale exports.
icon_output="$(mktemp -d "${TMPDIR:-/tmp}/spike-icon.XXXXXX")"
trap 'rm -rf -- "$icon_output"' EXIT
xcrun actool --compile "$icon_output" --app-icon SPIKE-icon --platform macosx \
    --minimum-deployment-target 14.0 --output-partial-info-plist "$icon_output/partial.plist" \
    --output-format human-readable-text --warnings --errors "$PWD/Branding/SPIKE-icon.icon"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/ModuleCache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swift build "${build_options[@]}"
binary_dir="$(swift build "${build_options[@]}" --show-bin-path)"
./build-media-helper.sh
if [[ "$configuration" == debug ]]; then
    "$binary_dir/ONESurfaceSpike" --self-test
fi
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$icon_output/Assets.car" "$icon_output/SPIKE-icon.icns" "$bundle/Contents/Resources/"
cp "$binary_dir/ONESurfaceSpike" "$bundle/Contents/MacOS/ONESurfaceSpike"
if [[ "$configuration" == release ]]; then
    # SwiftPM adds a toolchain search path; it is not part of a portable app.
    while IFS= read -r rpath; do
        if [[ "$rpath" == /Applications/*/Contents/Developer/* || "$rpath" == /Library/Developer/* ]]; then
            install_name_tool -delete_rpath "$rpath" "$bundle/Contents/MacOS/ONESurfaceSpike"
        fi
    done < <(otool -l "$bundle/Contents/MacOS/ONESurfaceSpike" | awk '/cmd LC_RPATH/{getline; getline; sub(/^ *path /, ""); sub(/ \(offset.*$/, ""); print}')
fi
cp "$PWD/Sources/ONESurfaceSpike/Resources/do.png" "$bundle/Contents/Resources/do.png"
cp "$PWD/Sources/ONESurfaceSpike/Resources/ASCIIFlow.metal" "$bundle/Contents/Resources/ASCIIFlow.metal"
cp "$PWD/Sources/ONESurfaceSpike/Resources/AudioVisualReferences-LICENSE.txt" "$bundle/Contents/Resources/AudioVisualReferences-LICENSE.txt"
mkdir -p "$bundle/Contents/Frameworks"
ditto "$PWD/.build/MediaRemoteAdapter.framework" "$bundle/Contents/Frameworks/MediaRemoteAdapter.framework"
cp "$PWD/vendor/mediaremote-adapter/bin/mediaremote-adapter.pl" "$bundle/Contents/Resources/mediaremote-adapter.pl"
cp "$PWD/vendor/mediaremote-adapter/LICENSE" "$bundle/Contents/Resources/MediaRemoteAdapter-LICENSE.txt"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ONESurfaceSpike</string>
<key>CFBundleIdentifier</key><string>local.one.surface-spike</string>
<key>CFBundleName</key><string>ONE Surface Spike</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSUIElement</key><true/>
<key>LSMultipleInstancesProhibited</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSCameraUsageDescription</key><string>SPIKE показывает камеру в Mirror. Снимки и видео сохраняются локально только по вашему нажатию или удержанию.</string>
<key>NSMicrophoneUsageDescription</key><string>SPIKE записывает микрофон только в видео Mirror, начатом вашим удержанием. Видео со звуком сохраняется локально в выбранную папку.</string>
<key>NSAudioCaptureUsageDescription</key><string>SPIKE анализирует общий выходной звук Mac для визуала в раскрытом Now Playing. Визуал можно выключить в настройках. Аудиосэмплы остаются в памяти, не сохраняются в файлы и не отправляются.</string>
<key>NSAppleEventsUsageDescription</key><string>SPIKE читает текущий трек и состояние Spotify и Music, чтобы музыка сохраняла приоритет над другими источниками, и управляет выбранным плеером по нажатию кнопок. Избранное Music меняется только по нажатию звёздочки.</string>
</dict></plist>
PLIST
for key in CFBundleIconFile CFBundleIconName; do
    plutil -insert "$key" -string "$(plutil -extract "$key" raw "$icon_output/partial.plist")" "$bundle/Contents/Info.plist"
done
if [[ "$configuration" == release ]]; then
    plutil -replace CFBundleName -string SPIKE "$bundle/Contents/Info.plist"
    plutil -insert CFBundleDisplayName -string SPIKE "$bundle/Contents/Info.plist"
    plutil -insert CFBundleShortVersionString -string 0.1.0 "$bundle/Contents/Info.plist"
fi
codesign --force --sign - "$bundle"
if [[ "$configuration" == release ]]; then
    codesign --verify --deep --strict "$bundle"
    "$bundle/Contents/MacOS/ONESurfaceSpike" --self-test
    print "Кандидат проверен локально. Подпись ad-hoc: при первом открытии может понадобиться исключение macOS."
    print "Для запуска без исключений нужны Developer ID и notarization. Целевая macOS ещё не проверена."
    print "Готово: $bundle"
    exit 0
fi
print "Готово: $bundle"
print "Если ONE уже работает, выйдите через правый клик по поверхности → Выйти из ONE Spike."
print "Затем откройте Запустить ONE.command в корне проекта."
