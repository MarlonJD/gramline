#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in run|--build-only|--verify|--debug|--logs|--telemetry) ;; *) echo "Usage: $0 [--build-only|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;; esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_NAME="Gramline"
BUNDLE_ID="dev.instadm.mac"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
export GOMODCACHE="$ROOT_DIR/.cache/go-mod"
export GOCACHE="$ROOT_DIR/.cache/go-build"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.cache/clang"

if [ "$MODE" != "--build-only" ]; then pkill -x "$APP_NAME" >/dev/null 2>&1 || true; fi
mkdir -p "$ROOT_DIR/.build"
(cd core && go build -trimpath -o "$ROOT_DIR/.build/insta-core" ./cmd/insta-core)
swift build --scratch-path "$ROOT_DIR/.build/swift" --cache-path "$ROOT_DIR/.cache/swift" --disable-sandbox
BUILD_DIR="$(swift build --scratch-path "$ROOT_DIR/.build/swift" --cache-path "$ROOT_DIR/.cache/swift" --disable-sandbox --show-bin-path)"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/.build/insta-core" "$APP_BUNDLE/Contents/MacOS/insta-core"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
"$ROOT_DIR/script/build_icon.sh"
cp "$ROOT_DIR/.build/Gramline.icns" "$APP_BUNDLE/Contents/Resources/"
cp "$ROOT_DIR/Resources/Brand/Gramline.png" "$APP_BUNDLE/Contents/Resources/"
if [ -d "$ROOT_DIR/Resources/ThirdParty" ]; then cp -R "$ROOT_DIR/Resources/ThirdParty" "$APP_BUNDLE/Contents/Resources/"; fi
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/insta-core"
# Local development signatures; this is not a Developer ID or notarized release.
/usr/bin/codesign --force --sign - --identifier "$BUNDLE_ID.core" "$APP_BUNDLE/Contents/MacOS/insta-core"
/usr/bin/codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
/usr/bin/codesign --verify --strict --deep "$APP_BUNDLE"

case "$MODE" in
  --build-only) echo "Built $APP_BUNDLE" ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "Gramline"' ;;
  --telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.instadm.mac"' ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 2; pgrep -x "$APP_NAME" >/dev/null; echo "Launched $APP_BUNDLE" ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
esac
