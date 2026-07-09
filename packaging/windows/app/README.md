# DriveBridge Windows 版

这个工具用于把飞书云盘、FTP 等远端存储挂载成 Windows 本地盘符，底层使用 rclone。Windows 包已内置运行飞书登录所需的 lark-cli 和 Node.js，普通用户不需要单独安装 lark-cli 或 Node.js。

普通用户只需要双击外层目录的 `启动飞书云盘.cmd`。`app` 目录是内部程序文件，通常不需要打开。`rclone-feishu.exe` 是命令行程序，双击它只会显示 rclone 帮助信息。

## 出处和许可证

本工具是基于 [rclone](https://github.com/rclone/rclone) 的非官方修改版/封装版，不是 rclone、飞书、Lark 或 Lark Technologies 的官方项目。

rclone 使用 MIT License，原始许可证随包保存在 `LICENSE.rclone.txt`。包内还包含 lark-cli 和 Node.js，许可证分别保存在 `LICENSE.lark-cli.txt` 和 `LICENSE.nodejs.txt`。第三方项目和服务说明见 `THIRD_PARTY_NOTICES.md`。

## 快速开始

1. 确认 WinFsp 可用。管理器会在挂载前自动检测 WinFsp，缺失时会尝试通过 winget 安装；也可以提前手动安装：

```powershell
winget install --id WinFsp.WinFsp --exact --accept-package-agreements --accept-source-agreements
```

2. 双击外层目录的 `启动飞书云盘.cmd`。
3. 选择 `挂载 / 启动`。
4. 选择连接类型。飞书会自动初始化飞书 CLI 配置并检查登录状态；FTP 会用中文表单要求填写主机、端口、用户名、密码、加密方式和远端目录。
5. 飞书连接会在挂载前用当前用户身份验证飞书云盘必要权限和列表权限；如果登录有效但权限不足，会重新打开授权并要求包含 `space:document:retrieve`、`drive:file`、`space:document:delete`。
6. 选择挂载盘符，例如 `X:`。

首次配置或切换配置后，工具会自动启用当前 Windows 用户的开机启动，不再额外询问。首次启动会立即在后台挂载，不需要重启 Windows。

## 常用入口

- `..\启动飞书云盘.cmd`：打开管理器菜单。
- `rclone-feishu-start.cmd`：内部兼容入口，普通用户不需要直接使用。
- `rclone-feishu-install-startup.cmd`：修复或重新启用开机启动。
- `rclone-feishu-refresh.cmd`：立即清理挂载目录缓存。
- `rclone-feishu-stop.cmd`：停止当前挂载。
- `rclone-feishu-diagnose.cmd`：输出 WinFsp、飞书登录、rclone、盘符和日志诊断信息。
- `rclone-feishu-uninstall.cmd`：停止挂载、移除开机启动，并可选择删除安装目录。

## 管理器菜单

- `挂载 / 启动`：首次运行时完成配置，自动启用开机启动，然后在后台挂载网盘。
- `切换连接类型或盘符`：停止当前挂载，重新选择飞书、SMB、FTP 或其他后端，并自动启用开机启动。
- `启用开机启动`：修复或重新启用当前用户的开机启动项。
- `关闭开机启动`：移除当前用户的开机启动项。
- `立即刷新缓存`：通过 rclone RC 清理目录缓存。
- `停止挂载`：停止当前托管的 rclone 挂载进程。
- `打开 rclone 高级配置`：进入 rclone 原生配置界面。
- `卸载`：移除开机启动、停止挂载，并可选择删除配置和安装目录。
- `诊断`：输出当前机器的挂载环境和错误日志，用于排查测试机问题。

## FTP 配置

选择 `FTP` 时，管理器会直接创建或更新 rclone 的 FTP 连接配置，不再进入 rclone 英文向导。需要填写：

- 主机：例如 `ftp.example.com` 或内网 IP。
- 加密方式：普通 FTP、显式 FTPS 或隐式 FTPS。
- 端口：普通 FTP 和显式 FTPS 默认 `21`，隐式 FTPS 默认 `990`。
- 用户名和密码：密码会写入 rclone 的加密配置，不写入 `rclone-feishu.settings.json`。
- 远端目录：直接回车表示 FTP 根目录；也可以填写 `/public` 这类子目录。

如果 FTP 连接配置被手动删除，请在管理器中选择 `切换连接类型或盘符` 后重新配置 FTP。

## 飞书授权排查

如果 WinFsp 和 rclone 都正常，但挂载后看不到飞书云盘内容，不要只检查 `auth status --verify`。该状态只能说明用户登录仍有效，不能证明云盘 API 权限可用。

当前管理器会在挂载前运行 `lark-cli auth check --scope "space:document:retrieve drive:file space:document:delete" --json` 和 `lark-cli drive files list --as user --json` 作为云盘权限预检。诊断菜单也会显示必要权限和 `drive files list` 的结果。若任一项失败，重新走飞书授权并确认授权包含 `space:document:retrieve`、`drive:file`、`space:document:delete`，再重试挂载。

如果在本地盘符里删除文件后，退出文件夹再进入又重新出现，通常说明远端删除没有成功。最常见原因是当前飞书登录缺少 `drive:file` 或 `space:document:delete` 删除权限；重新授权后再删除即可同步到远端。

## 同步行为

通过挂载盘写入的本地文件会由 rclone 上传到云端。

如果你直接在飞书云端删除文件，飞书不会向这个工具实时推送变更。当前挂载使用 `1s` 目录缓存，并提供 `立即刷新缓存` 功能。如果资源管理器仍显示云端已删除的文件，请运行 `rclone-feishu-refresh.cmd` 或在管理器中选择 `立即刷新缓存`。

严格的 Google Drive 客户端式实时同步，需要继续实现 Feishu 后端的变更通知或额外的同步守护进程。当前版本提供的是挂载能力和短缓存刷新，不是原生飞书桌面同步客户端。

## 已知限制

- 当前 Feishu 列表接口无法稳定返回普通文件真实大小，资源管理器中可能显示 `0 KB`，打开或下载文件后才能获得真实大小。
- 飞书在线文档会以 `.url` 快捷方式形式显示；删除该 `.url` 会删除对应的飞书在线文档。
- 开机启动只对当前 Windows 用户生效，不需要管理员权限。

## 文件说明

- `rclone-feishu-manager.ps1`：主管理器。
- `rclone-feishu.exe`：包含 Feishu 后端的 rclone 主程序。
- `tools\lark-cli`：包内置的 lark-cli 和 Node.js 运行时。
- `rclone-feishu.settings.json`：首次配置后生成的本地配置。
- `logs\mount.log`：挂载日志。
