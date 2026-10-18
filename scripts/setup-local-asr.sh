#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_ROOT="$PROJECT_ROOT/.runtime"
WHISPER_VERSION="v1.9.5"
WHISPER_SOURCE="$RUNTIME_ROOT/src/whisper.cpp"
WHISPER_BUILD="$RUNTIME_ROOT/build/whisper"
WHISPER_RUNTIME="$RUNTIME_ROOT/whisper"
MODEL_NAME="${1:-base}"
DOWNLOAD_SOURCE="${2:-${RUSTLE_MODEL_SOURCE:-huggingface}}"

# SHA-1 checksums published in the pinned whisper.cpp models/README.md.
case "$MODEL_NAME" in
    tiny) MODEL_SHA="bd577a113a864445d4c299885e0cb97d4ba92b5f" ;;
    base) MODEL_SHA="465707469ff3a37a2b9b8d8f89f2f99de7299dac" ;;
    small) MODEL_SHA="55356645c2b361a969dfd0ef2c5a50d530afd8d5" ;;
    large-v3-turbo-q5_0) MODEL_SHA="e050f7970618a659205450ad97eb95a18d69c9ee" ;;
    medium) MODEL_SHA="fd9727b6e1217c2f614f9b698455c4ffd82463b4" ;;
    large-v3) MODEL_SHA="ad82bf6a9043ceed055076d0fd39f5f186ff8062" ;;
    large-v3-turbo) MODEL_SHA="4af2b29d7ec73d781377bfd1758ca957a807e941" ;;
    *) printf '用法：%s [tiny|base|small|medium|large-v3|large-v3-turbo|large-v3-turbo-q5_0] [huggingface|hf-mirror|custom]\n' "$0" >&2; exit 2 ;;
esac

MODEL_FILENAME="ggml-$MODEL_NAME.bin"
case "$DOWNLOAD_SOURCE" in
    huggingface) MODEL_DOWNLOAD_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_FILENAME" ;;
    hf-mirror) MODEL_DOWNLOAD_URL="https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/$MODEL_FILENAME" ;;
    custom)
        MODEL_DOWNLOAD_URL="${RUSTLE_MODEL_URL:-}"
        if [[ -z "$MODEL_DOWNLOAD_URL" ]]; then
            printf '自定义下载源请设置 RUSTLE_MODEL_URL，可使用 {filename} 模板。\n' >&2
            exit 2
        fi
        MODEL_DOWNLOAD_URL="${MODEL_DOWNLOAD_URL//\{filename\}/$MODEL_FILENAME}"
        ;;
    *) printf '下载源须为 huggingface、hf-mirror 或 custom。\n' >&2; exit 2 ;;
esac

python3 - "$MODEL_DOWNLOAD_URL" <<'PY'
import sys
from urllib.parse import urlsplit
url = urlsplit(sys.argv[1])
valid_scheme = url.scheme == 'https' or (url.scheme == 'http' and url.hostname in ('localhost', '127.0.0.1', '::1'))
if not valid_scheme or not url.hostname or url.username or url.password or url.fragment:
    sys.exit('模型下载地址须为 HTTPS；本机服务可用 HTTP，地址中不能包含用户名、密码或片段。')
PY

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '此安装脚本用于 macOS 14 或更新版本。\n' >&2
    exit 1
fi
if ! xcrun --find clang >/dev/null 2>&1; then
    printf '请先安装 Apple Command Line Tools：xcode-select --install\n' >&2
    exit 1
fi
for TOOL in git curl shasum python3; do
    if ! command -v "$TOOL" >/dev/null 2>&1; then
        printf '缺少构建工具：%s\n' "$TOOL" >&2
        exit 1
    fi
done

mkdir -p "$RUNTIME_ROOT/src" "$RUNTIME_ROOT/build" "$RUNTIME_ROOT/models" "$WHISPER_RUNTIME/bin"

if command -v cmake >/dev/null 2>&1; then
    CMAKE="$(command -v cmake)"
else
    TOOL_ENV="$RUNTIME_ROOT/tools/venv"
    if [[ ! -x "$TOOL_ENV/bin/python" ]]; then
        python3 -m venv "$TOOL_ENV"
    fi
    if [[ ! -x "$TOOL_ENV/bin/cmake" ]]; then
        printf '在项目内部安装 CMake，系统 Python 与 Homebrew 不会被修改。\n'
        "$TOOL_ENV/bin/python" -m pip --disable-pip-version-check install --no-input --only-binary=:all: 'cmake==3.31.6'
    fi
    CMAKE="$TOOL_ENV/bin/cmake"
fi

if [[ ! -d "$WHISPER_SOURCE/.git" ]]; then
    if [[ -e "$WHISPER_SOURCE" ]]; then
        printf '源代码目录已存在但不是 Git 仓库：%s\n' "$WHISPER_SOURCE" >&2
        exit 1
    fi
    git clone --depth 1 --branch "$WHISPER_VERSION" https://github.com/ggml-org/whisper.cpp.git "$WHISPER_SOURCE"
fi
SOURCE_COMMIT="$(git -C "$WHISPER_SOURCE" rev-parse HEAD)"
TAG_COMMIT="$(git -C "$WHISPER_SOURCE" rev-parse "${WHISPER_VERSION}^{commit}")"
if [[ "$SOURCE_COMMIT" != "$TAG_COMMIT" ]]; then
    printf 'whisper.cpp 源码版本与固定版本 %s 不一致，请先检查 %s。\n' "$WHISPER_VERSION" "$WHISPER_SOURCE" >&2
    exit 1
fi

printf '编译 whisper.cpp %s（包含 Metal 与 Accelerate 支持）…\n' "$WHISPER_VERSION"
"$CMAKE" -S "$WHISPER_SOURCE" -B "$WHISPER_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_BACKEND_DL=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_OPENMP=OFF \
    -DGGML_NATIVE=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=ON \
    -DWHISPER_CURL=OFF
JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || printf '4')"
"$CMAKE" --build "$WHISPER_BUILD" --config Release --target whisper-cli --parallel "$JOBS"
cp "$WHISPER_BUILD/bin/whisper-cli" "$WHISPER_RUNTIME/bin/whisper-cli"
chmod +x "$WHISPER_RUNTIME/bin/whisper-cli"
cp "$WHISPER_SOURCE/LICENSE" "$WHISPER_RUNTIME/LICENSE"
printf 'Repository: https://github.com/ggml-org/whisper.cpp\nTag: %s\nCommit: %s\n' "$WHISPER_VERSION" "$SOURCE_COMMIT" > "$WHISPER_RUNTIME/SOURCE_VERSION.txt"

# The default build links whisper/ggml statically and embeds its Metal shaders.
# Copy any runtime libraries produced by a different compatible CMake toolchain.
while IFS= read -r -d '' LIBRARY; do
    cp -L "$LIBRARY" "$WHISPER_RUNTIME/bin/"
done < <(find "$WHISPER_BUILD" -type f \( -name '*.dylib' -o -name '*.metallib' \) -print0)

MODEL_PATH="$RUNTIME_ROOT/models/ggml-$MODEL_NAME.bin"
if [[ -f "$MODEL_PATH" ]] && [[ "$(shasum -a 1 "$MODEL_PATH" | awk '{print $1}')" == "$MODEL_SHA" ]]; then
    printf '本地模型校验通过：%s\n' "$MODEL_PATH"
else
    PARTIAL_PATH="$MODEL_PATH.download"
    printf '下载多语言 %s 模型，下载源：%s…\n' "$MODEL_NAME" "$DOWNLOAD_SOURCE"
    download_verified_model() {
        local source_url="$1"
        if ! curl --fail --location --retry 2 --connect-timeout 30 --speed-time 60 --speed-limit 1024 \
            --proto '=https,http' --proto-redir '=https' --output "$PARTIAL_PATH" "$source_url"; then
            return 1
        fi
        [[ "$(shasum -a 1 "$PARTIAL_PATH" | awk '{print $1}')" == "$MODEL_SHA" ]]
    }
    if ! download_verified_model "$MODEL_DOWNLOAD_URL"; then
        if [[ "${RUSTLE_MODEL_FALLBACK:-1}" == "1" && "$DOWNLOAD_SOURCE" != "custom" ]]; then
            if [[ "$DOWNLOAD_SOURCE" == "huggingface" ]]; then
                FALLBACK_URL="https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/$MODEL_FILENAME"
            else
                FALLBACK_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_FILENAME"
            fi
            printf '下载或校验失败，尝试另一下载源…\n' >&2
            if ! download_verified_model "$FALLBACK_URL"; then
                rm -f "$PARTIAL_PATH"
                printf '下载或校验失败，未替换现有模型。\n' >&2
                exit 1
            fi
        else
            rm -f "$PARTIAL_PATH"
            printf '下载或校验失败，未替换现有模型。\n' >&2
            exit 1
        fi
    fi
    mv "$PARTIAL_PATH" "$MODEL_PATH"
fi

printf '本地 ASR 已准备完成。\n可执行文件：%s\n模型：%s\n' "$WHISPER_RUNTIME/bin/whisper-cli" "$MODEL_PATH"
printf '自检示例：\n  "%s" -m "%s" -f "%s" -l en -oj -of "%s"\n' \
    "$WHISPER_RUNTIME/bin/whisper-cli" "$MODEL_PATH" "$WHISPER_SOURCE/samples/jfk.wav" "$RUNTIME_ROOT/jfk-result"
