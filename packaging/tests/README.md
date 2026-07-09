# DriveBridge 本地测试脚本

这里的脚本用于在没有外部服务器时验证 DriveBridge 使用的远端协议能力。

## FTP 冒烟测试

FTP 测试会在本机启动一个临时 `rclone serve ftp` 服务，然后再用另一个隔离的 rclone 配置连接它，验证：

- 能列出 FTP 根目录文件。
- 能创建远端目录。
- 能上传文件。
- 能读取上传后的文件内容。
- 能删除远端文件。

Windows：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\packaging\tests\local-ftp-smoke.ps1
```

指定已有可执行文件：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\packaging\tests\local-ftp-smoke.ps1 -RcloneExe .\rclone-feishu-cmount.exe
```

macOS / Linux：

```bash
./packaging/tests/local-ftp-smoke.sh
```

指定已有可执行文件：

```bash
RCLONE=/path/to/drivebridge-rclone ./packaging/tests/local-ftp-smoke.sh
```

默认监听 `127.0.0.1:52121`，被动端口范围为 `52200-52220`。如果端口被占用，可以指定端口：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\packaging\tests\local-ftp-smoke.ps1 -Port 53121
```

```bash
PORT=53121 ./packaging/tests/local-ftp-smoke.sh
```

脚本使用临时 `RCLONE_CONFIG`，不会污染用户的真实 rclone 配置。测试失败时会保留临时目录，里面包含 FTP 服务日志。
