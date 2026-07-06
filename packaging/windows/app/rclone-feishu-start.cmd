@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rclone-feishu-manager.ps1" -Action Menu
set "exitCode=%ERRORLEVEL%"

if not "%exitCode%"=="0" (
    exit /b %exitCode%
)

exit /b 0
