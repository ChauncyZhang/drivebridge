#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RCLONE="${RCLONE:-}"
PORT="${PORT:-52121}"
USER_NAME="${USER_NAME:-drivebridge}"
PASSWORD="${PASSWORD:-drivebridge-test}"

if [ -z "$RCLONE" ]; then
  if [ -x "$REPO_ROOT/dist/drivebridge-test" ]; then
    RCLONE="$REPO_ROOT/dist/drivebridge-test"
  else
    mkdir -p "$REPO_ROOT/dist"
    (cd "$REPO_ROOT" && go build -trimpath -o "$REPO_ROOT/dist/drivebridge-test" .)
    RCLONE="$REPO_ROOT/dist/drivebridge-test"
  fi
fi

if [ ! -x "$RCLONE" ]; then
  echo "[错误] rclone 不存在或不可执行：$RCLONE"
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/drivebridge-ftp-smoke.XXXXXX")"
FTP_ROOT="$WORK_DIR/ftp-root"
CLIENT_DIR="$WORK_DIR/client"
CONFIG_FILE="$WORK_DIR/rclone.conf"
SERVER_LOG="$WORK_DIR/ftp-server.log"
REMOTE_NAME="DriveBridgeLocalFtpSmoke"
SERVER_PID=""
SUCCESS="false"

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  if [ "$SUCCESS" = "true" ]; then
    rm -rf "$WORK_DIR"
  else
    echo "[提示] 测试失败，已保留临时目录：$WORK_DIR"
  fi
}
trap cleanup EXIT

mkdir -p "$FTP_ROOT" "$CLIENT_DIR"
printf "seed-from-ftp-server\n" > "$FTP_ROOT/server-seed.txt"
printf "upload-from-drivebridge\n" > "$CLIENT_DIR/upload.txt"

RCLONE_CONFIG="$CONFIG_FILE" "$RCLONE" serve ftp "$FTP_ROOT" \
  --addr "127.0.0.1:$PORT" \
  --user "$USER_NAME" \
  --pass "$PASSWORD" \
  --passive-port "52200-52220" \
  --log-file "$SERVER_LOG" \
  --log-level INFO &
SERVER_PID="$!"

ready="false"
for _ in $(seq 1 40); do
  sleep 0.25
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    echo "[错误] FTP 服务提前退出，日志：$SERVER_LOG"
    tail -n 80 "$SERVER_LOG" 2>/dev/null || true
    exit 1
  fi
  if (echo quit | nc 127.0.0.1 "$PORT" >/dev/null 2>&1); then
    ready="true"
    break
  fi
done

if [ "$ready" != "true" ]; then
  echo "[错误] FTP 服务未监听 127.0.0.1:$PORT，日志：$SERVER_LOG"
  tail -n 80 "$SERVER_LOG" 2>/dev/null || true
  exit 1
fi

run_rclone() {
  RCLONE_CONFIG="$CONFIG_FILE" "$RCLONE" "$@"
}

run_rclone config create "$REMOTE_NAME" ftp \
  host 127.0.0.1 \
  user "$USER_NAME" \
  port "$PORT" \
  pass "$PASSWORD" \
  --obscure \
  --non-interactive

run_rclone lsf "$REMOTE_NAME:" | grep -Fx "server-seed.txt" >/dev/null
run_rclone mkdir "$REMOTE_NAME:subdir"
run_rclone copyto "$CLIENT_DIR/upload.txt" "$REMOTE_NAME:subdir/upload.txt"
test "$(run_rclone cat "$REMOTE_NAME:subdir/upload.txt" | tr -d '\r\n')" = "upload-from-drivebridge"
run_rclone deletefile "$REMOTE_NAME:subdir/upload.txt"
if [ -e "$FTP_ROOT/subdir/upload.txt" ]; then
  echo "[错误] FTP 删除后文件仍然存在。"
  exit 1
fi

SUCCESS="true"
echo "[完成] 本地 FTP 冒烟测试通过。"
