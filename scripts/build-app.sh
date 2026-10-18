#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"

case "$CONFIGURATION" in
    debug|release) ;;
    *) printf '用法：%s [debug|release]\n' "$0" >&2; exit 2 ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'Rustle 需要在 macOS 14 或更新版本上构建。\n' >&2
    exit 1
fi

if ! xcrun --find swift >/dev/null 2>&1; then
    printf '请先安装 Apple Command Line Tools：xcode-select --install\n' >&2
    exit 1
fi

mkdir -p "$PROJECT_ROOT/.build/ModuleCache" "$PROJECT_ROOT/dist"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/ModuleCache"

BUILD_OPTIONS=(--package-path "$PROJECT_ROOT" --configuration "$CONFIGURATION")
if [[ "${RUSTLE_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
    BUILD_OPTIONS+=(--disable-sandbox)
fi

xcrun swift build "${BUILD_OPTIONS[@]}"
BIN_DIRECTORY="$(xcrun swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
APP_PATH="$PROJECT_ROOT/dist/Rustle.app"
STAGING_DIRECTORY="$(mktemp -d "$PROJECT_ROOT/dist/.rustle-build.XXXXXX")"
STAGED_APP="$STAGING_DIRECTORY/Rustle.app"
cleanup() {
    local status=$?
    if [[ "$status" != "0" && ! -e "$APP_PATH" && -d "$STAGING_DIRECTORY/previous-Rustle.app" ]]; then
        mv "$STAGING_DIRECTORY/previous-Rustle.app" "$APP_PATH"
    fi
    rm -rf "$STAGING_DIRECTORY"
    return "$status"
}
trap cleanup EXIT

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN_DIRECTORY/Rustle" "$STAGED_APP/Contents/MacOS/Rustle"
chmod +x "$STAGED_APP/Contents/MacOS/Rustle"
cp "$PROJECT_ROOT/packaging/Info.plist" "$STAGED_APP/Contents/Info.plist"
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"

# Keep SwiftPM resource bundles in the standard macOS application resource directory.
while IFS= read -r -d '' RESOURCE_BUNDLE; do
    cp -R "$RESOURCE_BUNDLE" "$STAGED_APP/Contents/Resources/"
done < <(find "$BIN_DIRECTORY" -maxdepth 1 -type d -name '*.bundle' -print0)

ICONSET_PATH="$STAGING_DIRECTORY/Rustle.iconset"
xcrun swift -module-cache-path "$PROJECT_ROOT/.build/ModuleCache" \
    "$PROJECT_ROOT/scripts/create-icon.swift" "$ICONSET_PATH" "$STAGED_APP/Contents/Resources/Rustle.icns"

WHISPER_RUNTIME="$PROJECT_ROOT/.runtime/whisper"
if [[ -x "$WHISPER_RUNTIME/bin/whisper-cli" ]]; then
    BUNDLED_WHISPER="$STAGED_APP/Contents/Resources/Whisper"
    mkdir -p "$BUNDLED_WHISPER"
    cp -R "$WHISPER_RUNTIME/bin/." "$BUNDLED_WHISPER/"
    for NOTICE in LICENSE SOURCE_VERSION.txt; do
        if [[ -f "$WHISPER_RUNTIME/$NOTICE" ]]; then
            cp "$WHISPER_RUNTIME/$NOTICE" "$BUNDLED_WHISPER/$NOTICE"
        fi
    done
else
    printf '本地 ASR 尚未安装。运行 ./scripts/setup-local-asr.sh 后重新打包即可内置离线转写。\n' >&2
fi

# Keep large model files outside the app; users select or download them in settings.
if [[ "${RUSTLE_BUNDLE_MODEL:-0}" == "1" ]]; then
    MODEL_PATH="${RUSTLE_WHISPER_MODEL:-$PROJECT_ROOT/.runtime/models/ggml-base.bin}"
    if [[ -f "$MODEL_PATH" ]]; then
        mkdir -p "$STAGED_APP/Contents/Resources/Models"
        cp "$MODEL_PATH" "$STAGED_APP/Contents/Resources/Models/$(basename "$MODEL_PATH")"
        basename "$MODEL_PATH" > "$STAGED_APP/Contents/Resources/Models/default-model.txt"
    fi
fi

/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist"
if command -v codesign >/dev/null 2>&1; then
    # Sign executable helpers explicitly; Resources is not a nested-code directory.
    if [[ -n "${BUNDLED_WHISPER:-}" ]]; then
        while IFS= read -r -d '' HELPER; do
            codesign --force --sign - "$HELPER"
        done < <(find "$BUNDLED_WHISPER" -type f \( -name 'whisper-cli' -o -name '*.dylib' \) -print0)
    fi
    codesign --force --deep --sign - --identifier dev.rustle.app "$STAGED_APP"
    codesign --verify --deep --strict "$STAGED_APP"
fi

# Replace a previous generated bundle only after every build and signing step succeeds.
if [[ -e "$APP_PATH" ]]; then
    mv "$APP_PATH" "$STAGING_DIRECTORY/previous-Rustle.app"
fi
mv "$STAGED_APP" "$APP_PATH"
printf '应用已生成：%s\n' "$APP_PATH"
