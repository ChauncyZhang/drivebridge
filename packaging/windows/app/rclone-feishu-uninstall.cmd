@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rclone-feishu-manager.ps1" -Action Uninstall
set "exitCode=%ERRORLEVEL%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rclone-feishu-pause.ps1" -ExitCode %exitCode%
exit /b %exitCode%
