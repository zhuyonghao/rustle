#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
mkdir -p "$PROJECT_ROOT/.build/ModuleCache"
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
    "$PROJECT_ROOT/Tests/MediaProgressIntegration.swift" \
    -o "$PROJECT_ROOT/.build/media-progress-integration"
cd "$PROJECT_ROOT"
"$PROJECT_ROOT/.build/media-progress-integration" "${1:?请传入待验证的媒体链接}"
