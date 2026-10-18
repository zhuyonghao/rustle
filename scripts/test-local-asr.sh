#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
mkdir -p "$PROJECT_ROOT/.build/ModuleCache"
if [[ ! -x "$PROJECT_ROOT/.runtime/whisper/bin/whisper-cli" || ! -f "$PROJECT_ROOT/.runtime/models/ggml-base.bin" ]]; then
    printf '请先运行 ./scripts/setup-local-asr.sh base 安装本地运行程序和多语言模型。\n' >&2
    exit 1
fi
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$PROJECT_ROOT/.build/ModuleCache" \
    "$PROJECT_ROOT/Sources/Rustle/Models/Models.swift" \
    "$PROJECT_ROOT/Sources/Rustle/Models/ProcessingProgress.swift" \
    "$PROJECT_ROOT/Sources/Rustle/Services/HTTPFileTransfer.swift" \
    "$PROJECT_ROOT/Sources/Rustle/Services/StreamingProcess.swift" \
    "$PROJECT_ROOT/Sources/Rustle/Services/ProcessingEngine.swift" \
    "$PROJECT_ROOT/Sources/Rustle/Services/ChatCompletionStream.swift" \
    "$PROJECT_ROOT/Sources/Rustle/Services/DashScopeASR.swift" \
    "$PROJECT_ROOT/Sources/Rustle/Services/LocalWhisperService.swift" \
    "$PROJECT_ROOT/Tests/LocalASRIntegration.swift" \
    -o "$PROJECT_ROOT/.build/local-integration"
cd "$PROJECT_ROOT"
"$PROJECT_ROOT/.build/local-integration"
