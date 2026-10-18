#!/bin/bash
set -euo pipefail

# Run the real test bodies without XCTest, which is absent from some CLT installs.
# Production code is compiled directly. Only framework imports are stripped from
# temporary test copies; the files in Tests/RustleTests remain untouched.
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'Rustle 的核心测试需要 macOS 14 或更新版本。\n' >&2
    exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
    printf '请先安装 Apple Command Line Tools：xcode-select --install\n' >&2
    exit 1
fi

mkdir -p "$PROJECT_ROOT/.build/CoreTests" "$PROJECT_ROOT/.build/ModuleCache"
CORE_BUILD="$(mktemp -d "$PROJECT_ROOT/.build/CoreTests/run.XXXXXX")"
trap 'rm -rf "$CORE_BUILD"' EXIT

export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/ModuleCache"

SOURCES=(
    "$PROJECT_ROOT/Sources/Rustle/AppStore.swift"
    "$PROJECT_ROOT/Sources/Rustle/WhisperModelManager.swift"
    "$PROJECT_ROOT/Sources/Rustle/Models/Models.swift"
    "$PROJECT_ROOT/Sources/Rustle/Models/WhisperModels.swift"
    "$PROJECT_ROOT/Sources/Rustle/Models/DemoContent.swift"
    "$PROJECT_ROOT/Sources/Rustle/Services/TranscriptExporter.swift"
    "$PROJECT_ROOT/Sources/Rustle/Services/MindMapImageExporter.swift"
    "$PROJECT_ROOT/Sources/Rustle/Views/Theme.swift"
    "$PROJECT_ROOT/Sources/Rustle/Services/CredentialStorage.swift"
    "$PROJECT_ROOT/Sources/Rustle/Services/ProcessingEngine.swift"
    "$PROJECT_ROOT/Sources/Rustle/Services/ChatCompletionStream.swift"
    "$PROJECT_ROOT/Sources/Rustle/Services/DashScopeASR.swift"
    "$PROJECT_ROOT/Sources/Rustle/Services/WhisperModelDownloader.swift"
    "$PROJECT_ROOT/Sources/Rustle/Models/ProcessingProgress.swift"
    "$PROJECT_ROOT/Sources/Rustle/Services/HTTPFileTransfer.swift"
    "$PROJECT_ROOT/Sources/Rustle/Services/StreamingProcess.swift"
    "$PROJECT_ROOT/Sources/Rustle/Services/RuntimeEnvironmentChecker.swift"
    "$PROJECT_ROOT/Sources/Rustle/Services/LibraryStorageMigration.swift"
    "$PROJECT_ROOT/Tests/CoreHarness.swift"
)
if [[ -f "$PROJECT_ROOT/Sources/Rustle/Services/LocalWhisperService.swift" ]]; then
    SOURCES+=("$PROJECT_ROOT/Sources/Rustle/Services/LocalWhisperService.swift")
fi

RUNNER="$CORE_BUILD/CoreTestMain.swift"
cat > "$RUNNER" <<'SWIFT'
import Foundation
@main struct CoreTestMain {
    static func main() async {
SWIFT

TEST_COUNT=0
for TEST_FILE in "$PROJECT_ROOT"/Tests/RustleTests/*Tests.swift; do
    [[ -f "$TEST_FILE" ]] || continue
    TEST_COPY="$CORE_BUILD/$(basename "$TEST_FILE")"
    printf 'import Foundation\n' > "$TEST_COPY"
    sed -e '/^import XCTest[[:space:]]*$/d' -e '/^@testable import Rustle[[:space:]]*$/d' "$TEST_FILE" >> "$TEST_COPY"
    SOURCES+=("$TEST_COPY")

    # XCTest cases in this project use parameterless methods with a single-line
    # signature. Discover synchronous, throwing, and asynchronous cases alike.
    awk '
        /^[[:space:]]*(final[[:space:]]+)?class[[:space:]]+[A-Za-z0-9_]+[[:space:]]*:[[:space:]]*XCTestCase/ {
            suite = $0
            sub(/^.*class[[:space:]]+/, "", suite)
            sub(/[[:space:]]*:.*$/, "", suite)
        }
        /^[[:space:]]*func[[:space:]]+test[A-Za-z0-9_]+\(\)/ {
            method = $0
            sub(/^.*func[[:space:]]+/, "", method)
            sub(/\(.*/, "", method)
            if (suite == "") { print "Test method without an XCTestCase class" > "/dev/stderr"; exit 1 }
            prefix = ""
            if ($0 ~ /[[:space:]]throws/) prefix = "try "
            if ($0 ~ /[[:space:]]async/) prefix = prefix "await "
            printf "        do {\n            let test = %s()\n", suite
            printf "            await CoreTestRunner.run(\"%s.%s\", testCase: test) { %stest.%s() }\n        }\n", suite, method, prefix, method
        }
    ' "$TEST_FILE" >> "$RUNNER"
    COUNT="$(awk '/^[[:space:]]*func[[:space:]]+test[A-Za-z0-9_]+\(\)/ { count++ } END { print count + 0 }' "$TEST_FILE")"
    TEST_COUNT=$((TEST_COUNT + COUNT))
done

if [[ "$TEST_COUNT" -eq 0 ]]; then
    printf '未发现核心测试，已停止，避免空测试被报告为通过。\n' >&2
    exit 1
fi
cat >> "$RUNNER" <<'SWIFT'
        exit(CoreTestRunner.finish())
    }
}
SWIFT

printf '正在编译 %s 项核心测试（无需 XCTest）…\n' "$TEST_COUNT"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    "${SOURCES[@]}" "$RUNNER" -o "$CORE_BUILD/RustleCoreTests"
"$CORE_BUILD/RustleCoreTests"
