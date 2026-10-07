#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

fail() { print -u2 -- "$1"; exit 1; }
if (( $# > 1 )); then
    fail "Использование: package-preview.command [--check | /полный/путь/новый.dmg]"
fi
bundle="$PWD/output/ONE Release Candidate.app"
plist="$bundle/Contents/Info.plist"
binary="$bundle/Contents/MacOS/ONESurfaceSpike"
helper="$bundle/Contents/Frameworks/MediaRemoteAdapter.framework/MediaRemoteAdapter"
project_root="${PWD:h:h}"
instruction="$project_root/docs/PREVIEW_INSTALL.txt"
[[ -x "$binary" && -f "$plist" && -f "$helper" && -f "$instruction" ]] ||
    fail "Сначала соберите release candidate; нужны app, helper и инструкция."
[[ "$(plutil -extract CFBundlePackageType raw "$plist")" == APPL &&
   "$(plutil -extract CFBundleExecutable raw "$plist")" == ONESurfaceSpike &&
   "$(plutil -extract CFBundleName raw "$plist")" == SPIKE ]] ||
    fail "Неверные metadata release candidate."
version="$(plutil -extract CFBundleShortVersionString raw "$plist")"
[[ "$version" == <->.<->.<-> ]] || fail "Некорректная версия release candidate."
architecture="$(lipo -archs "$binary")"
[[ "$architecture" == arm64 ]] || fail "Этот preview проверен только для arm64."
[[ "$(lipo -archs "$helper")" == "$architecture" ]] || fail "Архитектуры app/helper различаются."
for resource in Assets.car SPIKE-icon.icns do.png ASCIIFlow.metal AudioVisualReferences-LICENSE.txt MediaRemoteAdapter-LICENSE.txt mediaremote-adapter.pl; do
    [[ -f "$bundle/Contents/Resources/$resource" ]] || fail "Отсутствует resource: $resource"
done
[[ "$(plutil -extract CFBundleIconFile raw "$plist")" == SPIKE-icon &&
   "$(plutil -extract CFBundleIconName raw "$plist")" == SPIKE-icon ]] ||
    fail "Неверные metadata иконки release candidate."
cmp -s "$bundle/Contents/Resources/MediaRemoteAdapter-LICENSE.txt" "$PWD/vendor/mediaremote-adapter/LICENSE" ||
    fail "BSD notice отличается от исходника."
cmp -s "$bundle/Contents/Resources/AudioVisualReferences-LICENSE.txt" "$PWD/Sources/ONESurfaceSpike/Resources/AudioVisualReferences-LICENSE.txt" ||
    fail "MIT notice отличается от исходника."
codesign --verify --deep --strict "$bundle"
if [[ "${1:-}" == --check ]]; then
    print -- "Candidate проверен: SPIKE $version / $architecture. Системный первый запуск — отдельная проверка."
    exit 0
fi

image_path="${1:-$PWD/output/SPIKE-$version-preview-$architecture.dmg}"
[[ "$image_path" == /* && "$image_path" == *.dmg ]] || fail "Укажите абсолютный путь с окончанием .dmg."
[[ ! -e "$image_path" && ! -L "$image_path" && ! -e "$image_path.sha256.txt" && ! -L "$image_path.sha256.txt" ]] ||
    fail "Выходной файл уже существует; выберите новое имя."
task_stage="$(mktemp -d "${TMPDIR:-/tmp}/spike-package.XXXXXX")"
task_mounted=0
cleanup() {
    if (( task_mounted )); then
        if ! hdiutil detach "$task_stage/mount"; then
            print -u2 -- "Образ ещё подключён: $task_stage/mount. Временная папка сохранена."
            return
        fi
    fi
    rm -rf -- "$task_stage"
}
trap cleanup EXIT
mkdir -p "$task_stage/payload" "$task_stage/mount" "${image_path:h}"
ditto "$bundle" "$task_stage/payload/SPIKE.app"
ln -s /Applications "$task_stage/payload/Applications"
cp "$instruction" "$task_stage/payload/START.txt"
if [[ -f "$project_root/LICENSE" ]]; then
    cp "$project_root/LICENSE" "$task_stage/payload/LICENSE.txt"
else
    print -- "Собственная лицензия ещё не выбрана; пакет для локальной preview-проверки."
fi
hdiutil create -volname SPIKE -srcfolder "$task_stage/payload" -format UDZO "$task_stage/image.dmg"
hdiutil verify "$task_stage/image.dmg"
hdiutil attach -readonly -nobrowse -mountpoint "$task_stage/mount" "$task_stage/image.dmg"
task_mounted=1
codesign --verify --deep --strict "$task_stage/mount/SPIKE.app"
diff -rq "$bundle" "$task_stage/mount/SPIKE.app"
cmp "$instruction" "$task_stage/mount/START.txt"
[[ "$(readlink "$task_stage/mount/Applications")" == /Applications ]] || fail "Неверный Applications shortcut."
if [[ -f "$project_root/LICENSE" ]]; then
    cmp "$project_root/LICENSE" "$task_stage/mount/LICENSE.txt"
fi
hdiutil detach "$task_stage/mount"
task_mounted=0
# Recheck at creation time: a concurrent package must not be reported as ours.
setopt noclobber
cat "$task_stage/image.dmg" > "$image_path"
(
    cd "${image_path:h}"
    shasum -a 256 "${image_path:t}" > "${image_path:t}.sha256.txt"
)
print -- "Готово: $image_path"
print -- "Checksum: $image_path.sha256.txt"
