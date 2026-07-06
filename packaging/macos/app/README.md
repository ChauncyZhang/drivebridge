# DriveBridge macOS 版

这个包用于在 macOS 上把飞书云盘或其他 rclone 后端挂载成本地目录。普通用户只需要双击外层目录的 `启动DriveBridge.command`，`app` 目录是内部文件。

## 使用前准备

macOS 挂载需要安装 macFUSE：

```bash
brew install --cask macfuse
```

如果系统提示允许扩展，请在“系统设置 > 隐私与安全性”中允许 macFUSE，然后按系统提示重启。

飞书云盘需要安装并登录 lark-cli：

```bash
npm install -g @larksuite/cli
lark-cli config init --new
lark-cli auth login --domain drive --domain docs
```

## 快速开始

1. 双击外层目录的 `启动DriveBridge.command`。
2. 选择 `挂载 / 启动`。
3. 首次运行选择飞书云盘或其他后端。
4. 直接回车使用默认挂载目录，例如 `~/DriveBridge/Feishu`。

首次配置或切换配置后，工具会自动启用当前 macOS 用户的登录启动，不再额外询问。首次启动会立即在后台挂载，不需要重启 macOS。

如果 macOS 提示该脚本无法打开，请在终端里执行：

```bash
chmod +x 启动DriveBridge.command app/drivebridge-manager.sh app/drivebridge-rclone-*
```

## 管理器菜单

- `挂载 / 启动`：首次运行时完成配置，自动启用登录启动，然后在后台挂载。
- `切换连接类型或挂载目录`：停止当前挂载，重新选择飞书、SMB、FTP 或其他 rclone 后端。
- `启用登录启动`：安装当前用户的 LaunchAgent。
- `关闭登录启动`：移除当前用户的 LaunchAgent。
- `立即刷新缓存`：通过 rclone RC 清理目录缓存。
- `停止挂载`：停止当前后台挂载。
- `打开 rclone 高级配置`：进入 rclone 原生配置界面。
- `卸载`：移除登录启动、停止挂载，并可选择删除配置和安装目录。

## 文件说明

- `drivebridge-manager.sh`：macOS 管理器。
- `drivebridge-rclone-arm64`：Apple Silicon 使用的 rclone。
- `drivebridge-rclone-amd64`：Intel Mac 使用的 rclone。
- `drivebridge.settings`：首次配置后生成的本地配置。
- `logs/mount.log`：挂载日志。

## 出处和许可证

DriveBridge 是基于 rclone 的非官方修改版/封装版，不是 rclone、飞书、Lark 或 Lark Technologies 的官方项目。

rclone 使用 MIT License，原始许可证随包保存在 `LICENSE.rclone.txt`。第三方项目和服务说明见 `THIRD_PARTY_NOTICES.md`。
