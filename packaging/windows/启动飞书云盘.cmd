@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\rclone-feishu-manager.ps1" -Action Menu
exit /b %ERRORLEVEL%
