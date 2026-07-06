param(
    [string]$Action = "Menu"
)

$manager = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "rclone-feishu-manager.ps1"
& powershell -NoProfile -ExecutionPolicy Bypass -File $manager -Action $Action
exit $LASTEXITCODE
