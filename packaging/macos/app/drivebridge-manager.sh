#!/bin/bash
set -e

ACTION="${1:-menu}"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS_FILE="$ROOT_DIR/drivebridge.settings"
LOG_DIR="$ROOT_DIR/logs"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.drivebridge.mount.plist"

BACKEND="feishu"
REMOTE="Feishu"
MOUNT_POINT="$HOME/DriveBridge/Feishu"
AUTO_START="true"
CACHE_MODE="writes"
DIR_CACHE_TIME="1s"
ATTR_TIMEOUT="1s"
RC_ADDR="127.0.0.1:5574"

mkdir -p "$LOG_DIR"

if [ "$(uname -m)" = "arm64" ]; then
  RCLONE="$ROOT_DIR/drivebridge-rclone-arm64"
else
  RCLONE="$ROOT_DIR/drivebridge-rclone-amd64"
fi

shell_quote() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

load_settings() {
  if [ -f "$SETTINGS_FILE" ]; then
    # shellcheck disable=SC1090
    . "$SETTINGS_FILE"
  fi
}

save_settings() {
  {
    printf "BACKEND=%s\n" "$(shell_quote "$BACKEND")"
    printf "REMOTE=%s\n" "$(shell_quote "$REMOTE")"
    printf "MOUNT_POINT=%s\n" "$(shell_quote "$MOUNT_POINT")"
    printf "AUTO_START=%s\n" "$(shell_quote "$AUTO_START")"
    printf "CACHE_MODE=%s\n" "$(shell_quote "$CACHE_MODE")"
    printf "DIR_CACHE_TIME=%s\n" "$(shell_quote "$DIR_CACHE_TIME")"
    printf "ATTR_TIMEOUT=%s\n" "$(shell_quote "$ATTR_TIMEOUT")"
    printf "RC_ADDR=%s\n" "$(shell_quote "$RC_ADDR")"
  } > "$SETTINGS_FILE"
}

ensure_rclone() {
  if [ ! -f "$RCLONE" ]; then
    echo "[错误] 未找到 DriveBridge 主程序：$RCLONE"
    exit 1
  fi
  chmod +x "$RCLONE" 2>/dev/null || true
}

ensure_macos_fuse() {
  if [ -d "/Library/Filesystems/macfuse.fs" ]; then
    return
  fi
  if pkgutil --pkg-info io.macfuse.pkg.MacFUSE >/dev/null 2>&1; then
    return
  fi

  echo "[错误] 未检测到 macFUSE。"
  echo "请先安装 macFUSE："
  echo "  brew install --cask macfuse"
  echo "安装后如系统提示允许扩展，请在“系统设置 > 隐私与安全性”中允许 macFUSE。"
  exit 1
}

ensure_lark_login() {
  if ! command -v lark-cli >/dev/null 2>&1; then
    echo "[错误] 未找到 lark-cli。请先安装并登录："
    echo "  npm install -g @larksuite/cli"
    echo "  lark-cli config init --new"
    echo "  lark-cli auth login --domain drive --domain docs"
    exit 1
  fi

  echo "[检查] 正在验证飞书登录状态..."
  if ! lark-cli auth status --json --verify >/dev/null 2>&1; then
    echo "[登录] 正在打开飞书用户登录..."
    lark-cli auth login --domain drive --domain docs
  fi
  echo "[完成] 飞书登录状态有效。"
}

ensure_remote() {
  ensure_rclone
  if "$RCLONE" listremotes | grep -Fxq "$REMOTE:"; then
    echo "[完成] 连接配置 \"$REMOTE\" 已存在。"
    return
  fi

  if [ "$BACKEND" = "feishu" ]; then
    echo "[初始化] 正在创建飞书连接配置 \"$REMOTE\"。"
    "$RCLONE" config create "$REMOTE" feishu command lark-cli docs_as_url true
    return
  fi

  echo "[配置] 正在创建 $BACKEND 连接配置 \"$REMOTE\"。如出现 rclone 配置向导，请按提示完成。"
  "$RCLONE" config create "$REMOTE" "$BACKEND"
}

test_rc_online() {
  load_settings
  ensure_rclone
  "$RCLONE" rc --rc-addr "$RC_ADDR" --rc-no-auth core/stats >/dev/null 2>&1
}

xml_escape() {
  printf "%s" "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g'
}

test_startup_installed() {
  [ -f "$LAUNCH_AGENT" ] || return 1
  grep -Fq "$ROOT_DIR/drivebridge-manager.sh" "$LAUNCH_AGENT"
}

install_startup() {
  load_settings
  AUTO_START="true"
  save_settings

  mkdir -p "$HOME/Library/LaunchAgents"
  MANAGER_PATH="$ROOT_DIR/drivebridge-manager.sh"
  OUT_LOG="$LOG_DIR/launchd.out.log"
  ERR_LOG="$LOG_DIR/launchd.err.log"
  cat > "$LAUNCH_AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.drivebridge.mount</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml_escape "$MANAGER_PATH")</string>
    <string>mountsaved</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$OUT_LOG")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$ERR_LOG")</string>
</dict>
</plist>
EOF

  launchctl unload "$LAUNCH_AGENT" >/dev/null 2>&1 || true
  launchctl load -w "$LAUNCH_AGENT" >/dev/null 2>&1 || true
  echo "[完成] 已启用登录自启动。"
}

remove_startup() {
  load_settings
  AUTO_START="false"
  save_settings
  if [ -f "$LAUNCH_AGENT" ]; then
    launchctl unload "$LAUNCH_AGENT" >/dev/null 2>&1 || true
    rm -f "$LAUNCH_AGENT"
  fi
  echo "[完成] 已关闭登录自启动。"
}

select_settings() {
  echo "请选择要连接的类型："
  echo "1) 飞书云盘"
  echo "2) SMB"
  echo "3) FTP"
  echo "4) 其他 rclone 后端"
  printf "请选择 [默认：1]: "
  read -r choice
  [ -n "$choice" ] || choice="1"

  case "$choice" in
    1) BACKEND="feishu"; REMOTE="Feishu"; MOUNT_POINT="$HOME/DriveBridge/Feishu" ;;
    2) BACKEND="smb"; REMOTE="SMB"; MOUNT_POINT="$HOME/DriveBridge/SMB" ;;
    3) BACKEND="ftp"; REMOTE="FTP"; MOUNT_POINT="$HOME/DriveBridge/FTP" ;;
    4)
      printf "请输入 rclone 后端类型，例如 sftp、webdav、s3: "
      read -r BACKEND
      printf "请输入连接名称: "
      read -r REMOTE
      MOUNT_POINT="$HOME/DriveBridge/$REMOTE"
      ;;
    *) echo "[错误] 无效的连接类型选择。"; exit 1 ;;
  esac

  printf "请输入挂载目录，直接回车使用 %s: " "$MOUNT_POINT"
  read -r mount_input
  [ -n "$mount_input" ] && MOUNT_POINT="${mount_input/#\~/$HOME}"

  AUTO_START="true"
  save_settings
  install_startup >/dev/null
}

start_mount_worker_process() {
  nohup /bin/bash "$ROOT_DIR/drivebridge-manager.sh" mountworker >/dev/null 2>&1 &
}

mount_worker() {
  load_settings
  ensure_rclone
  ensure_macos_fuse
  mkdir -p "$MOUNT_POINT" "$LOG_DIR"
  exec "$RCLONE" mount "$REMOTE:" "$MOUNT_POINT" \
    --vfs-cache-mode "$CACHE_MODE" \
    --vfs-write-back 1s \
    --links \
    --dir-cache-time "$DIR_CACHE_TIME" \
    --attr-timeout "$ATTR_TIMEOUT" \
    --rc \
    --rc-addr "$RC_ADDR" \
    --rc-no-auth \
    --log-file "$LOG_DIR/mount.log" \
    --log-level INFO
}

start_mount() {
  allow_configure="${1:-true}"
  load_settings
  ensure_rclone

  if [ ! -f "$SETTINGS_FILE" ]; then
    if [ "$allow_configure" != "true" ]; then
      echo "[错误] 没有保存的配置。请先双击“启动DriveBridge.command”完成一次配置。"
      exit 1
    fi
    select_settings
  fi

  load_settings
  save_settings
  if [ "$AUTO_START" != "false" ] && ! test_startup_installed; then
    install_startup >/dev/null
  fi

  if test_rc_online; then
    echo "[提示] 托管挂载已在运行。"
    return
  fi

  ensure_remote
  if [ "$BACKEND" = "feishu" ]; then
    ensure_lark_login
  fi
  ensure_macos_fuse

  echo "[运行] 正在后台将 $REMOTE: 挂载到 $MOUNT_POINT"
  start_mount_worker_process

  i=0
  while [ "$i" -lt 10 ]; do
    sleep 0.5
    if test_rc_online; then
      echo "[完成] 挂载已在后台运行，可以关闭此窗口。"
      return
    fi
    i=$((i + 1))
  done

  echo "[提示] 已启动后台挂载进程，但尚未检测到运行状态。请稍后查看状态或日志：$LOG_DIR/mount.log"
}

stop_mount() {
  load_settings
  ensure_rclone
  if ! test_rc_online; then
    echo "[完成] 当前没有正在运行的托管挂载。"
    return
  fi
  "$RCLONE" rc --rc-addr "$RC_ADDR" --rc-no-auth core/quit >/dev/null 2>&1 || true
  echo "[完成] 已停止挂载。"
}

refresh_cache() {
  load_settings
  ensure_rclone
  if ! test_rc_online; then
    echo "[提示] 当前没有可连接的挂载进程。"
    return
  fi
  "$RCLONE" rc --rc-addr "$RC_ADDR" --rc-no-auth vfs/forget >/dev/null
  echo "[完成] 已清理挂载目录缓存。"
}

show_status() {
  load_settings
  echo "连接类型：$BACKEND"
  echo "连接名称：$REMOTE"
  echo "挂载目录：$MOUNT_POINT"
  if [ "$AUTO_START" = "false" ]; then
    echo "登录启动：已关闭"
  else
    echo "登录启动：已启用"
  fi
  if test_startup_installed; then
    echo "启动项  ：已安装"
  else
    echo "启动项  ：未安装"
  fi
  if test_rc_online; then
    echo "挂载状态：运行中"
  else
    echo "挂载状态：未运行"
  fi
}

open_config() {
  ensure_rclone
  "$RCLONE" config
}

uninstall_package() {
  echo "卸载将停止当前挂载、移除登录启动，并可选择删除安装目录。"
  printf "确认继续请输入 YES: "
  read -r confirm
  [ "$confirm" = "YES" ] || { echo "已取消。"; return; }

  remove_startup
  stop_mount

  printf "是否同时删除 rclone 连接配置？输入 YES 将删除 Feishu/SMB/FTP: "
  read -r remove_remote
  if [ "$remove_remote" = "YES" ]; then
    "$RCLONE" config delete Feishu >/dev/null 2>&1 || true
    "$RCLONE" config delete SMB >/dev/null 2>&1 || true
    "$RCLONE" config delete FTP >/dev/null 2>&1 || true
  fi

  printf "是否删除安装目录 \"%s\"？输入 YES: " "$(dirname "$ROOT_DIR")"
  read -r delete_folder
  if [ "$delete_folder" = "YES" ]; then
    parent="$(dirname "$ROOT_DIR")"
    nohup /bin/bash -c "sleep 2; rm -rf \"\$1\"" _ "$parent" >/dev/null 2>&1 &
    echo "[完成] 已安排删除安装目录。可以关闭此窗口。"
  fi
}

show_menu() {
  while true; do
    echo ""
    echo "===== DriveBridge 管理器 ====="
    show_status
    echo ""
    echo "1) 挂载 / 启动"
    echo "2) 切换连接类型或挂载目录"
    echo "3) 启用登录启动"
    echo "4) 关闭登录启动"
    echo "5) 立即刷新缓存"
    echo "6) 停止挂载"
    echo "7) 打开 rclone 高级配置"
    echo "8) 卸载"
    echo "0) 退出"
    printf "请选择: "
    read -r choice
    case "$choice" in
      1) start_mount true; return ;;
      2) stop_mount; select_settings; start_mount true; return ;;
      3) install_startup ;;
      4) remove_startup ;;
      5) refresh_cache ;;
      6) stop_mount ;;
      7) open_config ;;
      8) uninstall_package; return ;;
      0) return ;;
      *) echo "无效选择。" ;;
    esac
  done
}

case "$ACTION" in
  menu) show_menu ;;
  mount) start_mount true ;;
  mountsaved) start_mount false ;;
  mountworker) mount_worker ;;
  switch) stop_mount; select_settings; start_mount true ;;
  install-startup) install_startup ;;
  remove-startup) remove_startup ;;
  refresh) refresh_cache ;;
  unmount) stop_mount ;;
  status) show_status ;;
  uninstall) uninstall_package ;;
  config) open_config ;;
  *) echo "[错误] 未知动作：$ACTION"; exit 1 ;;
esac
