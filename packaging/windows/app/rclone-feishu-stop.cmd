@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rclone-feishu-manager.ps1" -Action Unmount
exit /b %ERRORLEVEL%
