param(
    [ValidateSet("Menu", "Mount", "MountSaved", "MountWorker", "Switch", "InstallStartup", "RemoveStartup", "Refresh", "Unmount", "Status", "Uninstall", "Config")]
    [string]$Action = "Menu"
)

$ErrorActionPreference = "Stop"

$rootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rcloneExe = Join-Path $rootDir "rclone-feishu.exe"
$settingsPath = Join-Path $rootDir "rclone-feishu.settings.json"
$logDir = Join-Path $rootDir "logs"
$startupName = "rclone-feishu-mount.vbs"
$bundledLarkCliDir = Join-Path $rootDir "tools\lark-cli"
$defaultSettings = [ordered]@{
    Backend = "feishu"
    Remote = "Feishu"
    MountPoint = "X:"
    AutoStart = "true"
    CacheMode = "writes"
    DirCacheTime = "1s"
    AttrTimeout = "1s"
    RcAddr = "127.0.0.1:5574"
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Initialize-BundledTools {
    if (Test-Path -LiteralPath (Join-Path $bundledLarkCliDir "lark-cli.cmd")) {
        $env:PATH = "$bundledLarkCliDir;$env:PATH"
    }
}

Initialize-BundledTools

function Get-Settings {
    $settings = [ordered]@{}
    foreach ($key in $defaultSettings.Keys) {
        $settings[$key] = $defaultSettings[$key]
    }
    if (Test-Path -LiteralPath $settingsPath) {
        $loaded = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        foreach ($prop in $loaded.PSObject.Properties) {
            if ($settings.Contains($prop.Name)) {
                $settings[$prop.Name] = [string]$prop.Value
            }
        }
    }
    return [pscustomobject]$settings
}

function Save-Settings {
    param([pscustomobject]$Settings)
    $Settings | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding ASCII
}

function Ensure-Rclone {
    if (-not (Test-Path -LiteralPath $rcloneExe)) {
        throw "未找到 rclone 主程序：$rcloneExe"
    }
}

function Invoke-Rclone {
    param([string[]]$RcloneArgs)
    Ensure-Rclone
    & $rcloneExe @RcloneArgs
    return $LASTEXITCODE
}

function Invoke-LarkCli {
    param(
        [string[]]$CliArgs,
        [switch]$Quiet
    )

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($Quiet) {
            & lark-cli @CliArgs *> $null
        }
        else {
            & lark-cli @CliArgs
        }
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
}

function Ensure-LarkLogin {
    if (-not (Get-Command lark-cli -ErrorAction SilentlyContinue)) {
        throw "未找到 lark-cli。安装包可能不完整，请确认 app\tools\lark-cli 存在。"
    }

    Write-Host "[检查] 正在检查飞书 CLI 配置..."
    if ((Invoke-LarkCli -CliArgs @("config", "show") -Quiet) -ne 0) {
        Write-Host "[初始化] 首次使用需要初始化飞书登录配置。"
        Write-Host "[提示] 如果命令行显示验证链接，请复制到浏览器完成授权；完成后回到此窗口继续。"
        if ((Invoke-LarkCli -CliArgs @("config", "init", "--new", "--brand", "feishu", "--lang", "zh")) -ne 0) {
            throw "飞书 CLI 初始化失败"
        }
    }

    Write-Host "[检查] 正在验证飞书登录状态..."
    if ((Invoke-LarkCli -CliArgs @("auth", "status", "--json", "--verify") -Quiet) -ne 0) {
        Write-Host "[登录] 正在打开飞书用户登录..."
        if ((Invoke-LarkCli -CliArgs @("auth", "login", "--domain", "drive", "--domain", "docs")) -ne 0) {
            throw "飞书用户登录失败"
        }
    }
    Write-Host "[完成] 飞书登录状态有效。"
}

function Ensure-Remote {
    param([string]$Remote, [string]$Backend)

    $list = & $rcloneExe listremotes
    if ($list -contains "${Remote}:") {
        Write-Host "[完成] 连接配置 `"$Remote`" 已存在。"
        return
    }

    if ($Backend -ieq "feishu") {
        Write-Host "[初始化] 正在创建飞书连接配置 `"$Remote`"。"
        & $rcloneExe config create $Remote feishu command lark-cli docs_as_url true
        if ($LASTEXITCODE -ne 0) {
            throw "创建飞书连接配置失败"
        }
        return
    }

    Write-Host "[配置] 正在创建 $Backend 连接配置 `"$Remote`"。如出现 rclone 配置向导，请按提示完成。"
    & $rcloneExe config create $Remote $Backend
    if ($LASTEXITCODE -ne 0) {
        throw "创建 $Backend 连接配置失败"
    }
}

function Normalize-MountPoint {
    param([string]$MountPoint)
    if ([string]::IsNullOrWhiteSpace($MountPoint)) {
        $MountPoint = $defaultSettings.MountPoint
    }
    $MountPoint = $MountPoint.Trim()
    if (-not $MountPoint.EndsWith(":")) {
        $MountPoint += ":"
    }
    return $MountPoint.ToUpperInvariant()
}

function Select-BackendSettings {
    $choice = Read-Host "请选择要连接的类型：`n1) 飞书云盘`n2) SMB`n3) FTP`n4) 其他 rclone 后端`n[默认：1]"
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }

    switch ($choice) {
        "1" { $backend = "feishu"; $remote = "Feishu" }
        "2" { $backend = "smb"; $remote = "SMB" }
        "3" { $backend = "ftp"; $remote = "FTP" }
        "4" {
            $backend = Read-Host "请输入 rclone 后端类型，例如 sftp、webdav、s3"
            $remote = Read-Host "请输入连接名称"
        }
        default { throw "无效的连接类型选择" }
    }

    if ([string]::IsNullOrWhiteSpace($backend) -or [string]::IsNullOrWhiteSpace($remote)) {
        throw "后端类型和连接名称不能为空"
    }

    $settings = Get-Settings
    $settings.Backend = $backend.Trim()
    $settings.Remote = $remote.Trim()
    $settings.MountPoint = Normalize-MountPoint (Read-Host "请输入挂载盘符，例如 X:，直接回车使用 $($settings.MountPoint)")
    $settings.AutoStart = "true"
    Save-Settings $settings
    Install-Startup -Silent -NoPersist
    return $settings
}

function Get-RcArgs {
    $settings = Get-Settings
    return @("--rc-addr", $settings.RcAddr, "--rc-no-auth")
}

function Get-StartupFile {
    $startupDir = [Environment]::GetFolderPath("Startup")
    return Join-Path $startupDir $startupName
}

function Test-StartupInstalled {
    $startupFile = Get-StartupFile
    if (-not (Test-Path -LiteralPath $startupFile)) {
        return $false
    }
    $script = Join-Path $rootDir "rclone-feishu-manager.ps1"
    try {
        $content = Get-Content -LiteralPath $startupFile -Raw
        return ($content -like "*$script*")
    }
    catch {
        return $false
    }
}

function Test-AutoStartEnabled {
    param([string]$Value)
    return ($Value -notmatch '^(false|0|no|n)$')
}

function Test-RcOnline {
    $settings = Get-Settings
    try {
        & $rcloneExe rc --rc-addr $settings.RcAddr --rc-no-auth core/stats *> $null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

function Refresh-Cache {
    Ensure-Rclone
    if (-not (Test-RcOnline)) {
        Write-Host "[提示] 当前没有可连接的挂载进程。"
        return
    }
    $settings = Get-Settings
    & $rcloneExe rc --rc-addr $settings.RcAddr --rc-no-auth vfs/forget | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "刷新挂载缓存失败"
    }
    Write-Host "[完成] 已清理挂载目录缓存。"
}

function Stop-Mount {
    Ensure-Rclone
    if (-not (Test-RcOnline)) {
        Write-Host "[完成] 当前没有正在运行的托管挂载。"
        return
    }
    $settings = Get-Settings
    & $rcloneExe rc --rc-addr $settings.RcAddr --rc-no-auth core/quit | Out-Null
    Write-Host "[完成] 已停止挂载。"
}

function Show-Status {
    $settings = Get-Settings
    Write-Host "连接类型：$($settings.Backend)"
    Write-Host "连接名称：$($settings.Remote)"
    Write-Host "挂载盘符：$($settings.MountPoint)"
    Write-Host "开机启动：$(if (Test-AutoStartEnabled $settings.AutoStart) { '已启用' } else { '已关闭' })"
    Write-Host "启动项  ：$(if (Test-StartupInstalled) { '已安装' } else { '未安装' })"
    Write-Host "挂载状态：$(if (Test-RcOnline) { '运行中' } else { '未运行' })"
}

function Get-MountArgs {
    param([pscustomobject]$Settings)

    $logFile = Join-Path $logDir "mount.log"
    return @(
        "mount", "$($Settings.Remote):", $Settings.MountPoint,
        "--vfs-cache-mode", $Settings.CacheMode,
        "--vfs-write-back", "1s",
        "--links",
        "--dir-cache-time", $Settings.DirCacheTime,
        "--attr-timeout", $Settings.AttrTimeout,
        "--rc",
        "--rc-addr", $Settings.RcAddr,
        "--rc-no-auth",
        "--log-file", $logFile,
        "--log-level", "INFO"
    )
}

function Start-MountWorkerProcess {
    $script = Join-Path $rootDir "rclone-feishu-manager.ps1"
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-WindowStyle", "Hidden",
        "-File", "`"$script`"",
        "-Action", "MountWorker"
    )
    Start-Process -FilePath "powershell.exe" -ArgumentList $args -WindowStyle Hidden | Out-Null
}

function Invoke-MountWorker {
    Ensure-Rclone
    Ensure-Directory $logDir
    $settings = Get-Settings
    $settings.MountPoint = Normalize-MountPoint $settings.MountPoint
    $mountArgs = Get-MountArgs -Settings $settings
    & $rcloneExe @mountArgs
}

function Start-Mount {
    param(
        [bool]$Interactive,
        [bool]$AllowConfigure = $true
    )

    Ensure-Rclone
    Ensure-Directory $logDir

    if ($Interactive -or -not (Test-Path -LiteralPath $settingsPath)) {
        if (-not $AllowConfigure) {
            throw "没有保存的配置。请先运行 rclone-feishu-start.cmd 完成一次配置。"
        }
        $settings = Select-BackendSettings
    }
    else {
        $settings = Get-Settings
    }

    $settings.MountPoint = Normalize-MountPoint $settings.MountPoint
    Save-Settings $settings
    if ((Test-AutoStartEnabled $settings.AutoStart) -and -not (Test-StartupInstalled)) {
        Install-Startup -Silent -NoPersist
    }

    if (Test-RcOnline) {
        Write-Host "[提示] 托管挂载已在运行。如需重新挂载，请先停止当前挂载。"
        return
    }

    Ensure-Remote -Remote $settings.Remote -Backend $settings.Backend
    if ($settings.Backend -ieq "feishu") {
        Ensure-LarkLogin
    }

    Write-Host "[运行] 正在后台将 $($settings.Remote): 挂载到 $($settings.MountPoint)"
    Start-MountWorkerProcess

    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-RcOnline) {
            Write-Host "[完成] 挂载已在后台运行，可以关闭此窗口。"
            return
        }
    }

    Write-Host "[提示] 已启动后台挂载进程，但尚未检测到运行状态。请稍后在管理器中查看状态；日志位置：$(Join-Path $logDir 'mount.log')"
}

function Install-Startup {
    param(
        [switch]$Silent,
        [switch]$NoPersist
    )
    Ensure-Rclone
    $settings = Get-Settings
    if (-not $NoPersist) {
        $settings.AutoStart = "true"
    }
    Save-Settings $settings

    $script = Join-Path $rootDir "rclone-feishu-manager.ps1"
    $startupFile = Get-StartupFile
    $escapedScript = $script.Replace('"', '""')
    $vbs = @"
Set shell = CreateObject("WScript.Shell")
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$escapedScript"" -Action MountSaved", 0, False
"@
    $vbs | Set-Content -LiteralPath $startupFile -Encoding Unicode
    if (-not $Silent) {
        Write-Host "[完成] 已安装开机启动项：$startupFile"
    }
}

function Remove-Startup {
    param(
        [switch]$Silent,
        [switch]$NoPersist
    )
    if (-not $NoPersist) {
        $settings = Get-Settings
        $settings.AutoStart = "false"
        Save-Settings $settings
    }
    $startupFile = Get-StartupFile
    if (-not (Test-Path -LiteralPath $startupFile)) {
        if (-not $Silent) {
            Write-Host "[完成] 当前未安装开机启动项。"
        }
        return
    }
    Remove-Item -LiteralPath $startupFile -Force
    if (-not $Silent) {
        Write-Host "[完成] 已移除开机启动项。"
    }
}

function Open-RcloneConfig {
    Ensure-Rclone
    & $rcloneExe config
}

function Uninstall-Package {
    Write-Host "卸载将停止当前挂载、移除开机启动，并可选择删除安装目录。"
    $confirm = Read-Host "确认继续请输入 YES"
    if ($confirm -ne "YES") {
        Write-Host "已取消。"
        return
    }

    Remove-Startup
    Stop-Mount

    $removeRemote = Read-Host "是否同时删除 rclone 连接配置？输入 YES 将删除 Feishu/SMB/FTP"
    if ($removeRemote -eq "YES") {
        foreach ($remote in @("Feishu", "SMB", "FTP")) {
            & $rcloneExe config delete $remote *> $null
        }
    }

    $deleteFolder = Read-Host "是否删除安装目录 `"$rootDir`"？输入 YES"
    if ($deleteFolder -eq "YES") {
        $cleanup = Join-Path $env:TEMP "rclone-feishu-uninstall.ps1"
        $escaped = $rootDir.Replace("'", "''")
        @"
Start-Sleep -Seconds 2
Remove-Item -LiteralPath '$escaped' -Recurse -Force
"@ | Set-Content -LiteralPath $cleanup -Encoding ASCII
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$cleanup`""
        Write-Host "[完成] 已安排删除安装目录。可以关闭此窗口。"
    }
}

function Show-Menu {
    while ($true) {
        Write-Host ""
        Write-Host "===== rclone-feishu 管理器 ====="
        Show-Status
        Write-Host ""
        $choice = Read-Host "1) 挂载 / 启动`n2) 切换连接类型或盘符`n3) 启用开机启动`n4) 关闭开机启动`n5) 立即刷新缓存`n6) 停止挂载`n7) 打开 rclone 高级配置`n8) 卸载`n0) 退出`n请选择"
        switch ($choice) {
            "1" { Start-Mount -Interactive:$false -AllowConfigure:$true; return }
            "2" { Stop-Mount; Start-Mount -Interactive:$true -AllowConfigure:$true; return }
            "3" { Install-Startup }
            "4" { Remove-Startup }
            "5" { Refresh-Cache }
            "6" { Stop-Mount }
            "7" { Open-RcloneConfig }
            "8" { Uninstall-Package; return }
            "0" { return }
            default { Write-Host "无效选择。" }
        }
    }
}

try {
    switch ($Action) {
        "Menu" { Show-Menu }
        "Mount" { Start-Mount -Interactive:$true -AllowConfigure:$true }
        "MountSaved" { Start-Mount -Interactive:$false -AllowConfigure:$false }
        "MountWorker" { Invoke-MountWorker }
        "Switch" { Stop-Mount; Start-Mount -Interactive:$true -AllowConfigure:$true }
        "InstallStartup" { Install-Startup }
        "RemoveStartup" { Remove-Startup }
        "Refresh" { Refresh-Cache }
        "Unmount" { Stop-Mount }
        "Status" { Show-Status }
        "Uninstall" { Uninstall-Package }
        "Config" { Open-RcloneConfig }
    }
}
catch {
    Write-Host "[错误] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
