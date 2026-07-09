# DriveBridge macOS 版

这个包用于在 macOS 上把飞书云盘挂载成本地目录。普通用户只需要双击外层目录的 `启动DriveBridge.command`，`app` 目录是内部文件。

当前 macOS 版已对齐飞书主流程：自动创建 Feishu 连接、初始化飞书 CLI、检查用户登录、检查云盘权限、后台挂载、登录启动、停止、刷新、卸载和诊断。FTP 会使用中文表单配置主机、端口、用户名、密码、加密方式和远端目录。SMB/其他 rclone 后端保留入口，但仍走 rclone 原生配置界面。

## 使用前准备

macOS 挂载需要安装 macFUSE：

```bash
brew install --cask macfuse
```

如果系统提示允许扩展，请在“系统设置 > 隐私与安全性”中允许 macFUSE，然后按系统提示重启。

完整安装包会尽量内置 lark-cli。如果当前包没有内置，飞书云盘需要先安装 lark-cli：

```bash
npm install -g @larksuite/cli
```

首次挂载时管理器会自动执行飞书 CLI 初始化和用户授权。需要授权的范围是：

```text
space:document:retrieve drive:file space:document:delete
```

## 快速开始

1. 双击外层目录的 `启动DriveBridge.command`。
2. 选择 `挂载 / 启动`。
3. 首次运行直接回车使用默认飞书云盘和默认挂载目录 `~/DriveBridge/Feishu`。
4. 如果窗口显示飞书验证链接，请复制到浏览器完成授权，然后回到窗口继续。

首次配置或切换配置后，工具会自动启用当前 macOS 用户的登录启动，不再额外询问。首次启动会立即在后台挂载，不需要重启 macOS。

如果 macOS 提示该脚本无法打开，请在终端里执行：

```bash
chmod +x 启动DriveBridge.command app/drivebridge-manager.sh app/drivebridge-rclone-*
```

## 管理器菜单

- `挂载 / 启动`：首次运行时完成配置、登录和权限检查，自动启用登录启动，然后在后台挂载。
- `切换连接类型或挂载目录`：停止当前挂载，重新选择飞书、SMB、FTP 或其他 rclone 后端。
- `启用登录启动`：安装当前用户的 LaunchAgent。
- `关闭登录启动`：移除当前用户的 LaunchAgent。
- `立即刷新缓存`：通过 rclone RC 清理目录缓存。
- `停止挂载`：停止当前后台挂载。
- `打开 rclone 高级配置`：进入 rclone 原生配置界面。
- `卸载`：移除登录启动、停止挂载，并可选择删除配置和安装目录。
- `诊断`：输出 macFUSE、lark-cli、飞书权限、rclone 远端、RC 状态、挂载目录和最近日志。

## FTP 配置

选择 `FTP` 时，管理器会直接创建或更新 rclone 的 FTP 连接配置，不再进入 rclone 英文向导。需要填写：

- 主机：例如 `ftp.example.com` 或内网 IP。
- 加密方式：普通 FTP、显式 FTPS 或隐式 FTPS。
- 端口：普通 FTP 和显式 FTPS 默认 `21`，隐式 FTPS 默认 `990`。
- 用户名和密码：密码会写入 rclone 的加密配置，不写入 `drivebridge.settings`。
- 远端目录：直接回车表示 FTP 根目录；也可以填写 `/public` 这类子目录。

没有现成 FTP 服务器时，可以在仓库源码目录运行本地模拟测试。它会临时启动一个本机 FTP 服务，然后验证列表、上传、读取和删除：

```bash
./packaging/tests/local-ftp-smoke.sh
```

## 行为说明

- 本地上传、删除普通文件会通过 rclone 写回飞书云盘。
- 飞书在线文档会以 `.url` 文件显示。删除对应 `.url` 文件会删除远端在线文档。
- 飞书云端主动删除后，macOS 挂载目录可能需要等待短缓存过期；也可以在管理器中选择 `立即刷新缓存`。
- 飞书在线文档不是普通二进制文件，大小可能显示为 `0 KB`；普通上传文件会尽量显示真实大小。

## 文件说明

- `drivebridge-manager.sh`：macOS 管理器。
- `drivebridge-rclone-arm64`：Apple Silicon 使用的 rclone。
- `drivebridge-rclone-amd64`：Intel Mac 使用的 rclone。
- `tools/lark-cli/lark-cli`：可选的内置飞书 CLI。
- `drivebridge.settings`：首次配置后生成的本地配置。
- `logs/mount.log`：挂载日志。

## 构建包

在 macOS 上从仓库根目录执行：

```bash
./packaging/macos/build-package.sh host
```

如果当前 Mac 环境具备对应架构的 cgo 构建能力，也可以生成双架构包：

```bash
./packaging/macos/build-package.sh both
```

如果构建时报 `fatal error: 'fuse.h' file not found`，说明当前机器缺少 macFUSE 开发头文件，或者头文件不在常见路径。先查找：

```bash
sudo find /Library/Filesystems/macfuse.fs /usr/local/include /opt/homebrew/include -name fuse.h -print
```

如果能找到 `fuse.h`，把包含 `fuse.h` 的目录传给构建脚本：

```bash
DRIVEBRIDGE_FUSE_INCLUDE=/path/to/include/that/contains/fuse.h ./packaging/macos/build-package.sh host
```

## 出处和许可证

DriveBridge 是基于 rclone 的非官方修改版/封装版，不是 rclone、飞书、Lark 或 Lark Technologies 的官方项目。

rclone 使用 MIT License，原始许可证随包保存在 `LICENSE.rclone.txt`。第三方项目和服务说明见 `THIRD_PARTY_NOTICES.md`。
