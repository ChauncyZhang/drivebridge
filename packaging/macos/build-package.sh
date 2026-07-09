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

append_unique_flag() {
  current="$1"
  flag="$2"
  case " $current " in
    *" $flag "*) printf "%s" "$current" ;;
    *) printf "%s %s" "$current" "$flag" ;;
  esac
}

find_fuse_include_dir() {
  if [ -n "${DRIVEBRIDGE_FUSE_INCLUDE:-}" ] && [ -f "$DRIVEBRIDGE_FUSE_INCLUDE/fuse.h" ]; then
    printf "%s" "$DRIVEBRIDGE_FUSE_INCLUDE"
    return
  fi

  candidates="
/usr/local/include/osxfuse/fuse
/usr/local/include/fuse
/opt/homebrew/include/osxfuse/fuse
/opt/homebrew/include/fuse
/opt/local/include/fuse
/Library/Filesystems/macfuse.fs/Contents/Resources/include
/Library/Filesystems/macfuse.fs/Contents/Resources/include/fuse
/Library/Filesystems/macfuse.fs/Contents/Resources/include/osxfuse/fuse
"

  if command -v brew >/dev/null 2>&1; then
    brew_prefix="$(brew --prefix 2>/dev/null || true)"
    if [ -n "$brew_prefix" ]; then
      candidates="$candidates
$brew_prefix/include/osxfuse/fuse
$brew_prefix/include/fuse"
    fi
  fi

  for candidate in $candidates; do
    if [ -f "$candidate/fuse.h" ]; then
      printf "%s" "$candidate"
      return
    fi
  done
}

prepare_fuse_build_env() {
  fuse_include="$(find_fuse_include_dir || true)"
  if [ -z "$fuse_include" ]; then
    echo "[提示] 未找到 macFUSE 开发头文件 fuse.h。"
    echo "       将构建不依赖 FUSE 头文件的 NFS 挂载版。"
    echo "       如果你希望构建 FUSE 版，请先确认 macFUSE 开发头文件位置："
    echo "  sudo find /Library/Filesystems/macfuse.fs /usr/local/include /opt/homebrew/include -name fuse.h -print"
    echo "       如果找到了 fuse.h，请这样指定目录后重试："
    echo "  DRIVEBRIDGE_FUSE_INCLUDE=/path/to/include/that/contains/fuse.h ./packaging/macos/build-package.sh host"
    return 1
  fi

  export CGO_CFLAGS="$(append_unique_flag "${CGO_CFLAGS:-}" "-I$fuse_include")"
  echo "[检查] macFUSE 头文件：$fuse_include"
  return 0
}

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

BUILD_TAGS=""
BUILD_CGO="0"
BUILD_MOUNT_MODE="nfs"
if prepare_fuse_build_env; then
  BUILD_TAGS="cmount"
  BUILD_CGO="1"
  BUILD_MOUNT_MODE="fuse"
fi

for target_arch in $ARCHES; do
  echo "[构建] drivebridge-rclone-$target_arch ($BUILD_MOUNT_MODE)"
  (
    cd "$REPO_ROOT"
    if [ -n "$BUILD_TAGS" ]; then
      GOOS=darwin GOARCH="$target_arch" CGO_ENABLED="$BUILD_CGO" \
        go build -trimpath -tags "$BUILD_TAGS" -ldflags "-s -w" \
        -o "$APP_OUT/drivebridge-rclone-$target_arch" .
    else
      GOOS=darwin GOARCH="$target_arch" CGO_ENABLED="$BUILD_CGO" \
        go build -trimpath -ldflags "-s -w" \
        -o "$APP_OUT/drivebridge-rclone-$target_arch" .
    fi
  )
  chmod +x "$APP_OUT/drivebridge-rclone-$target_arch"
done

printf "%s\n" "$BUILD_MOUNT_MODE" > "$APP_OUT/mount-mode.txt"

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
