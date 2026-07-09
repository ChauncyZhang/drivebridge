#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "[错误] macOS 包需要在 macOS 上构建。"
  exit 1
fi

ARCH="${1:-host}"
ZIP="${ZIP:-true}"

case "$ARCH" in
  host)
    case "$(uname -m)" in
      arm64) ARCHES="arm64" ;;
      x86_64) ARCHES="amd64" ;;
      *) echo "[错误] 不支持的 Mac 架构：$(uname -m)"; exit 1 ;;
    esac
    ;;
  arm64) ARCHES="arm64" ;;
  amd64|x86_64) ARCHES="amd64" ;;
  both|universal) ARCHES="arm64 amd64" ;;
  *)
    echo "用法：$0 [host|arm64|amd64|both]"
    exit 1
    ;;
esac

OUTPUT_DIR="$REPO_ROOT/dist/drivebridge-macos-$ARCH"
APP_OUT="$OUTPUT_DIR/app"

rm -rf "$OUTPUT_DIR" "$OUTPUT_DIR.zip" "$OUTPUT_DIR.zip.sha256.txt"
mkdir -p "$APP_OUT/logs"

cp "$SCRIPT_DIR/启动DriveBridge.command" "$OUTPUT_DIR/"
cp -R "$SCRIPT_DIR/app/." "$APP_OUT/"
cp "$REPO_ROOT/COPYING" "$APP_OUT/LICENSE.rclone.txt"
cp "$REPO_ROOT/NOTICE.md" "$APP_OUT/"
cp "$REPO_ROOT/THIRD_PARTY_NOTICES.md" "$APP_OUT/"

for target_arch in $ARCHES; do
  echo "[构建] drivebridge-rclone-$target_arch"
  (
    cd "$REPO_ROOT"
    GOOS=darwin GOARCH="$target_arch" CGO_ENABLED=1 \
      go build -trimpath -tags cmount -ldflags "-s -w" \
      -o "$APP_OUT/drivebridge-rclone-$target_arch" .
  )
  chmod +x "$APP_OUT/drivebridge-rclone-$target_arch"
done

if command -v npm >/dev/null 2>&1; then
  NPM_ROOT="$(npm root -g 2>/dev/null || true)"
  LARK_PACKAGE="$NPM_ROOT/@larksuite/cli"
  LARK_NATIVE="$LARK_PACKAGE/bin/lark-cli"
  if [ -x "$LARK_NATIVE" ]; then
    mkdir -p "$APP_OUT/tools/lark-cli"
    cp "$LARK_NATIVE" "$APP_OUT/tools/lark-cli/lark-cli"
    chmod +x "$APP_OUT/tools/lark-cli/lark-cli"
    if [ -f "$LARK_PACKAGE/LICENSE" ]; then
      cp "$LARK_PACKAGE/LICENSE" "$APP_OUT/LICENSE.lark-cli.txt"
    fi
  else
    echo "[提示] 未找到 @larksuite/cli 原生可执行文件，包内不会内置飞书 CLI。"
    echo "       用户需自行安装：npm install -g @larksuite/cli"
  fi
else
  echo "[提示] 未找到 npm，包内不会内置飞书 CLI。用户需自行安装：npm install -g @larksuite/cli"
fi

chmod +x "$OUTPUT_DIR/启动DriveBridge.command" "$APP_OUT/drivebridge-manager.sh"

if [ "$ZIP" = "true" ]; then
  (
    cd "$REPO_ROOT/dist"
    ditto -c -k --keepParent "$(basename "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR").zip"
    shasum -a 256 "$(basename "$OUTPUT_DIR").zip" > "$(basename "$OUTPUT_DIR").zip.sha256.txt"
  )
fi

echo "[完成] macOS 包已生成：$OUTPUT_DIR"
