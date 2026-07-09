#!/bin/bash
set -e

ACTION="${1:-menu}"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS_FILE="$ROOT_DIR/drivebridge.settings"
LOG_DIR="$ROOT_DIR/logs"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.drivebridge.mount.plist"
REQUIRED_FEISHU_SCOPES="space:document:retrieve drive:file space:document:delete"

BACKEND="feishu"
REMOTE="Feishu"
REMOTE_PATH=""
MOUNT_POINT="$HOME/DriveBridge/Feishu"
AUTO_START="true"
CACHE_MODE="writes"
DIR_CACHE_TIME="1s"
ATTR_TIMEOUT="1s"
RC_ADDR="127.0.0.1:5574"

mkdir -p "$LOG_DIR"

case "$(uname -m)" in
  arm64) RCLONE="$ROOT_DIR/drivebridge-rclone-arm64" ;;
  *) RCLONE="$ROOT_DIR/drivebridge-rclone-amd64" ;;
esac

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
    printf "REMOTE_PATH=%s\n" "$(shell_quote "$REMOTE_PATH")"
    printf "MOUNT_POINT=%s\n" "$(shell_quote "$MOUNT_POINT")"
    printf "AUTO_START=%s\n" "$(shell_quote "$AUTO_START")"
    printf "CACHE_MODE=%s\n" "$(shell_quote "$CACHE_MODE")"
    printf "DIR_CACHE_TIME=%s\n" "$(shell_quote "$DIR_CACHE_TIME")"
    printf "ATTR_TIMEOUT=%s\n" "$(shell_quote "$ATTR_TIMEOUT")"
    printf "RC_ADDR=%s\n" "$(shell_quote "$RC_ADDR")"
  } > "$SETTINGS_FILE"
}

initialize_bundled_tools() {
  if [ -x "$ROOT_DIR/tools/lark-cli/lark-cli" ]; then
    export PATH="$ROOT_DIR/tools/lark-cli:$PATH"
  fi
}

ensure_rclone() {
  if [ ! -f "$RCLONE" ]; then
    echo "[错误] 未找到 DriveBridge 主程序：$RCLONE"
    echo "请确认 macOS 包内包含 drivebridge-rclone-arm64 或 drivebridge-rclone-amd64。"
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

find_macos_fuse_library() {
  if [ -n "${CGOFUSE_LIBFUSE_PATH:-}" ] && [ -f "$CGOFUSE_LIBFUSE_PATH" ]; then
    printf "%s" "$CGOFUSE_LIBFUSE_PATH"
    return
  fi

  for candidate in \
    "/usr/local/lib/libfuse.2.dylib" \
    "/usr/local/lib/libosxfuse.2.dylib" \
    "/opt/homebrew/lib/libfuse.2.dylib" \
    "/opt/homebrew/lib/libosxfuse.2.dylib" \
    "/opt/local/lib/libfuse.2.dylib" \
    "/Library/Filesystems/macfuse.fs/Contents/Resources/lib/libfuse.2.dylib" \
    "/Library/Filesystems/macfuse.fs/Contents/Resources/lib/libosxfuse.2.dylib"; do
    if [ -f "$candidate" ]; then
      printf "%s" "$candidate"
      return
    fi
  done
}

initialize_macos_fuse_runtime() {
  fuse_library="$(find_macos_fuse_library || true)"
  if [ -n "$fuse_library" ]; then
    export CGOFUSE_LIBFUSE_PATH="$fuse_library"
  fi
}

invoke_lark_quiet() {
  lark-cli "$@" >/dev/null 2>&1
}

test_lark_config() {
  invoke_lark_quiet config show
}

test_lark_auth() {
  invoke_lark_quiet auth status --json --verify
}

test_lark_required_scopes() {
  invoke_lark_quiet auth check --scope "$REQUIRED_FEISHU_SCOPES" --json
}

test_lark_drive_access() {
  invoke_lark_quiet drive files list --as user --json
}

read_required_text() {
  prompt="$1"
  while true; do
    printf "%s: " "$prompt" >&2
    read -r value
    value="$(printf "%s" "$value" | sed 's#^[[:space:]]*##; s#[[:space:]]*$##')"
    if [ -n "$value" ]; then
      printf "%s" "$value"
      return
    fi
    echo "[提示] 不能为空。" >&2
  done
}

read_text_with_default() {
  prompt="$1"
  default_value="$2"
  printf "%s [默认：%s]: " "$prompt" "$default_value" >&2
  read -r value
  value="$(printf "%s" "$value" | sed 's#^[[:space:]]*##; s#[[:space:]]*$##')"
  if [ -z "$value" ]; then
    printf "%s" "$default_value"
  else
    printf "%s" "$value"
  fi
}

ensure_lark_login() {
  initialize_bundled_tools
  if ! command -v lark-cli >/dev/null 2>&1; then
    echo "[错误] 未找到 lark-cli。请先安装 @larksuite/cli，或使用内置 lark-cli 的完整安装包。"
    echo "  npm install -g @larksuite/cli"
    exit 1
  fi

  echo "[检查] 正在检查飞书 CLI 配置..."
  if ! test_lark_config; then
    echo "[初始化] 首次使用需要初始化飞书登录配置。"
    echo "[提示] 如果命令行显示验证链接，请复制到浏览器完成授权；完成后回到此窗口继续。"
    if ! lark-cli config init --new --brand feishu --lang zh; then
      if ! test_lark_config; then
        echo "[错误] 飞书 CLI 初始化失败"
        exit 1
      fi
      echo "[提示] 飞书 CLI 已写入配置，继续登录流程。"
    fi
  fi

  echo "[检查] 正在验证飞书登录状态..."
  if ! test_lark_auth; then
    echo "[登录] 正在打开飞书用户登录..."
    if ! lark-cli auth login --domain drive --domain docs --scope "$REQUIRED_FEISHU_SCOPES"; then
      if ! test_lark_auth; then
        echo "[错误] 飞书用户登录失败"
        exit 1
      fi
      echo "[提示] 飞书用户登录状态有效，继续挂载流程。"
    fi
  fi

  echo "[检查] 正在验证飞书云盘必要权限..."
  if ! test_lark_required_scopes; then
    echo "[授权] 当前用户缺少飞书云盘必要权限，正在重新打开飞书授权。"
    if ! lark-cli auth login --domain drive --domain docs --scope "$REQUIRED_FEISHU_SCOPES"; then
      if ! test_lark_required_scopes; then
        echo "[错误] 飞书云盘授权失败。请确认授权包含：$REQUIRED_FEISHU_SCOPES。"
        exit 1
      fi
    fi
    if ! test_lark_required_scopes; then
      echo "[错误] 飞书云盘授权后仍缺少必要权限：$REQUIRED_FEISHU_SCOPES。"
      exit 1
    fi
  fi

  echo "[检查] 正在验证飞书云盘访问权限..."
  if ! test_lark_drive_access; then
    echo "[授权] 当前用户缺少飞书云盘访问授权，正在重新打开飞书授权。"
    if ! lark-cli auth login --domain drive --domain docs --scope "$REQUIRED_FEISHU_SCOPES"; then
      if ! test_lark_drive_access; then
        echo "[错误] 飞书云盘授权失败。请确认授权包含：$REQUIRED_FEISHU_SCOPES。"
        exit 1
      fi
    fi
    if ! test_lark_drive_access; then
      echo "[错误] 飞书云盘授权后仍无法访问。请运行诊断查看 lark-cli 与远端列表。"
      exit 1
    fi
  fi
  echo "[完成] 飞书登录状态有效。"
}

normalize_remote_path() {
  value="${1:-}"
  value="$(printf "%s" "$value" | sed 's#\\#/#g' | sed 's#^[[:space:]]*##; s#[[:space:]]*$##')"
  if [ -z "$value" ] || [ "$value" = "/" ]; then
    printf ""
    return
  fi
  case "$value" in
    /*) printf "%s" "$value" ;;
    *) printf "/%s" "$value" ;;
  esac
}

get_remote_spec() {
  path_part="$(normalize_remote_path "$REMOTE_PATH")"
  if [ -z "$path_part" ]; then
    printf "%s:" "$REMOTE"
  else
    printf "%s:%s" "$REMOTE" "$path_part"
  fi
}

ensure_remote() {
  ensure_rclone
  if [ "$BACKEND" = "ftp" ]; then
    if "$RCLONE" listremotes | grep -Fxq "$REMOTE:"; then
      echo "[完成] FTP 连接配置 \"$REMOTE\" 已存在。"
      return
    fi
    echo "[错误] FTP 连接配置不存在。请在管理器中选择 切换连接类型或挂载目录 后重新配置 FTP。"
    exit 1
  fi

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

configure_ftp_remote() {
  ensure_rclone
  echo "[配置] 正在配置 FTP 连接 \"$REMOTE\"。"

  host_name="$(read_required_text "请输入 FTP 主机，例如 ftp.example.com")"
  echo "请选择加密方式："
  echo "1) 普通 FTP"
  echo "2) 显式 FTPS"
  echo "3) 隐式 FTPS"
  printf "请选择 [默认：1]: "
  read -r tls_choice
  [ -n "$tls_choice" ] || tls_choice="1"

  case "$tls_choice" in
    1) tls="false"; explicit_tls="false"; default_port="21" ;;
    2) tls="false"; explicit_tls="true"; default_port="21" ;;
    3) tls="true"; explicit_tls="false"; default_port="990" ;;
    *) echo "[错误] 无效的 FTP 加密方式选择。"; exit 1 ;;
  esac

  port="$(read_text_with_default "请输入 FTP 端口" "$default_port")"
  case "$port" in
    ''|*[!0-9]*) echo "[错误] FTP 端口必须是数字。"; exit 1 ;;
  esac

  default_user="$(id -un 2>/dev/null || printf "anonymous")"
  user="$(read_text_with_default "请输入 FTP 用户名" "$default_user")"
  printf "请输入 FTP 密码；匿名或无密码时直接回车: "
  stty -echo 2>/dev/null || true
  read -r password
  stty echo 2>/dev/null || true
  printf "\n"

  config_action="create"
  config_args=("config" "create" "$REMOTE" "ftp")
  if "$RCLONE" listremotes | grep -Fxq "$REMOTE:"; then
    config_action="update"
    config_args=("config" "update" "$REMOTE")
  fi

  config_args+=(
    "host" "$host_name"
    "user" "$user"
    "port" "$port"
    "tls" "$tls"
    "explicit_tls" "$explicit_tls"
    "--obscure"
    "--non-interactive"
  )

  if [ -n "$password" ]; then
    config_args=("config" "$config_action")
    if [ "$config_action" = "create" ]; then
      config_args+=("$REMOTE" "ftp")
    else
      config_args+=("$REMOTE")
    fi
    config_args+=(
      "host" "$host_name"
      "user" "$user"
      "port" "$port"
      "pass" "$password"
      "tls" "$tls"
      "explicit_tls" "$explicit_tls"
      "--obscure"
      "--non-interactive"
    )
  fi

  "$RCLONE" "${config_args[@]}"
  password=""
  echo "[完成] FTP 连接配置已保存。"
}

test_rc_online() {
  load_settings
  ensure_rclone
  "$RCLONE" rc --rc-addr "$RC_ADDR" --rc-no-auth core/stats >/dev/null 2>&1
}

test_mount_point_ready() {
  load_settings
  [ -d "$MOUNT_POINT" ] || return 1
  mount_dev="$(stat -f "%d" "$MOUNT_POINT" 2>/dev/null || true)"
  parent_dev="$(stat -f "%d" "$(dirname "$MOUNT_POINT")" 2>/dev/null || true)"
  [ -n "$mount_dev" ] && [ -n "$parent_dev" ] && [ "$mount_dev" != "$parent_dev" ]
}

get_mount_status_text() {
  if ! test_rc_online; then
    printf "未运行"
    return
  fi
  if test_mount_point_ready; then
    printf "运行中"
    return
  fi
  printf "运行中但挂载目录不可用"
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
    1) BACKEND="feishu"; REMOTE="Feishu"; REMOTE_PATH=""; MOUNT_POINT="$HOME/DriveBridge/Feishu" ;;
    2) BACKEND="smb"; REMOTE="SMB"; REMOTE_PATH=""; MOUNT_POINT="$HOME/DriveBridge/SMB" ;;
    3) BACKEND="ftp"; REMOTE="FTP"; REMOTE_PATH=""; MOUNT_POINT="$HOME/DriveBridge/FTP" ;;
    4)
      printf "请输入 rclone 后端类型，例如 sftp、webdav、s3: "
      read -r BACKEND
      printf "请输入连接名称: "
      read -r REMOTE
      REMOTE_PATH=""
      MOUNT_POINT="$HOME/DriveBridge/$REMOTE"
      ;;
    *) echo "[错误] 无效的连接类型选择。"; exit 1 ;;
  esac

  if [ "$BACKEND" = "ftp" ]; then
    configure_ftp_remote
    printf "请输入 FTP 远端目录，例如 / 或 /public，直接回车使用根目录: "
    read -r ftp_remote_path
    REMOTE_PATH="$(normalize_remote_path "$ftp_remote_path")"
  else
    REMOTE_PATH=""
  fi

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
  initialize_macos_fuse_runtime
  mkdir -p "$MOUNT_POINT" "$LOG_DIR"
  remote_spec="$(get_remote_spec)"
  exec "$RCLONE" mount "$remote_spec" "$MOUNT_POINT" \
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

reset_mount_log() {
  : > "$LOG_DIR/mount.log"
}

mount_failure_from_log() {
  [ -f "$LOG_DIR/mount.log" ] || return 1
  grep -E "CRITICAL|Fatal error|failed to mount|cannot find|mount stopped" "$LOG_DIR/mount.log" | tail -n 1
}

start_mount() {
  allow_configure="${1:-true}"
  load_settings
  ensure_rclone

  if [ ! -f "$SETTINGS_FILE" ]; then
    if [ "$allow_configure" != "true" ]; then
      echo "[错误] 没有保存的配置。请先双击 启动DriveBridge.command 完成一次配置。"
      exit 1
    fi
    select_settings
  fi

  load_settings
  save_settings
  if [ "$AUTO_START" != "false" ] && ! test_startup_installed; then
    install_startup >/dev/null
  fi

  ensure_remote
  if [ "$BACKEND" = "feishu" ]; then
    ensure_lark_login
  fi
  ensure_macos_fuse

  if test_rc_online && test_mount_point_ready; then
    echo "[提示] 托管挂载已在运行，连接状态已检查。"
    return
  fi
  if test_rc_online; then
    echo "[提示] 检测到后台进程在线但挂载目录不可用，正在重启挂载。"
    stop_mount
    sleep 1
  fi

  reset_mount_log
  remote_spec="$(get_remote_spec)"
  echo "[运行] 正在后台将 $remote_spec 挂载到 $MOUNT_POINT"
  start_mount_worker_process

  i=0
  while [ "$i" -lt 20 ]; do
    sleep 0.5
    if test_rc_online && test_mount_point_ready; then
      echo "[完成] 挂载已在后台运行，可以关闭此窗口。"
      return
    fi
    failure="$(mount_failure_from_log || true)"
    if [ -n "$failure" ]; then
      echo "[错误] 挂载失败：$failure"
      exit 1
    fi
    i=$((i + 1))
  done

  failure="$(mount_failure_from_log || true)"
  if [ -n "$failure" ]; then
    echo "[错误] 挂载失败：$failure"
    exit 1
  fi
  echo "[错误] 后台挂载进程已启动，但挂载目录 $MOUNT_POINT 仍不可访问。日志位置：$LOG_DIR/mount.log"
  exit 1
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
  remote_path="$(normalize_remote_path "$REMOTE_PATH")"
  [ -n "$remote_path" ] && echo "远端目录：$remote_path"
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
  echo "挂载状态：$(get_mount_status_text)"
}

diagnostic_command() {
  title="$1"
  shift
  echo ""
  echo "[$title]"
  "$@" || echo "退出码：$?"
}

show_diagnostics() {
  load_settings
  echo "===== DriveBridge 诊断 ====="
  echo "程序目录：$ROOT_DIR"
  echo "rclone ：$RCLONE"
  echo "连接类型：$BACKEND"
  echo "连接名称：$REMOTE"
  remote_path="$(normalize_remote_path "$REMOTE_PATH")"
  if [ -z "$remote_path" ]; then
    echo "远端目录：/"
  else
    echo "远端目录：$remote_path"
  fi
  echo "挂载目录：$MOUNT_POINT"
  echo "RC 地址 ：$RC_ADDR"
  if test_startup_installed; then
    echo "启动项  ：已安装"
  else
    echo "启动项  ：未安装"
  fi
  echo "挂载状态：$(get_mount_status_text)"

  echo ""
  echo "[macFUSE]"
  if [ -d "/Library/Filesystems/macfuse.fs" ] || pkgutil --pkg-info io.macfuse.pkg.MacFUSE >/dev/null 2>&1; then
    echo "macFUSE：已检测到"
  else
    echo "macFUSE：未检测到"
  fi

  if [ "$BACKEND" = "feishu" ]; then
    echo ""
    echo "[lark-cli]"
    if command -v lark-cli >/dev/null 2>&1; then
      echo "lark-cli：$(command -v lark-cli)"
      lark-cli --version || true
    else
      echo "lark-cli：未找到"
    fi
    echo "config show：$(test_lark_config && echo 成功 || echo 失败)"
    echo "auth status --verify：$(test_lark_auth && echo 成功 || echo 失败)"
    echo "必要权限：$(test_lark_required_scopes && echo 成功 || echo 失败)"
    echo "权限列表：$REQUIRED_FEISHU_SCOPES"
    echo "drive files list：$(test_lark_drive_access && echo 成功 || echo 失败)"
  fi

  echo ""
  echo "[rclone]"
  ensure_rclone
  "$RCLONE" version || true
  "$RCLONE" listremotes || true

  echo ""
  echo "[远端列表]"
  "$RCLONE" lsjson "$(get_remote_spec)" --max-depth 1 --low-level-retries 1 --retries 1 || true

  echo ""
  echo "[RC 状态]"
  "$RCLONE" rc --rc-addr "$RC_ADDR" --rc-no-auth core/stats || true

  echo ""
  echo "[挂载目录访问]"
  echo "test -d $MOUNT_POINT：$(test -d "$MOUNT_POINT" && echo True || echo False)"
  if [ -d "$MOUNT_POINT" ]; then
    ls -la "$MOUNT_POINT" | head -n 25 || true
  fi

  echo ""
  echo "[mount.log 最近 120 行]"
  if [ -f "$LOG_DIR/mount.log" ]; then
    tail -n 120 "$LOG_DIR/mount.log"
  else
    echo "日志不存在：$LOG_DIR/mount.log"
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
    echo "9) 诊断"
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
      9) show_diagnostics ;;
      0) return ;;
      *) echo "无效选择。" ;;
    esac
  done
}

initialize_bundled_tools

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
  diagnose) show_diagnostics ;;
  uninstall) uninstall_package ;;
  config) open_config ;;
  *) echo "[错误] 未知动作：$ACTION"; exit 1 ;;
esac
