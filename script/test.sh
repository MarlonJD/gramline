#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export GOMODCACHE="$ROOT_DIR/.cache/go-mod"
export GOCACHE="$ROOT_DIR/.cache/go-build"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.cache/clang"
(cd core && go test -race ./... go.mau.fi/mautrix-meta/pkg/messagix/bloks go.mau.fi/mautrix-meta/pkg/messagix/httpclient)
swift test --scratch-path "$ROOT_DIR/.build/swift" --cache-path "$ROOT_DIR/.cache/swift" --disable-sandbox
python3 script/smoke_test.py "$ROOT_DIR/dist/Gramline.app/Contents/MacOS/insta-core"
