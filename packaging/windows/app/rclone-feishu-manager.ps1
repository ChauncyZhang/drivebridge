param(
    [ValidateSet("Menu", "Mount", "MountSaved", "MountWorker", "Switch", "InstallStartup", "RemoveStartup", "Refresh", "Unmount", "Status", "Uninstall", "Config", "Diagnose")]
    [string]$Action = "Menu"
)

$ErrorActionPreference = "Stop"

$rootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rcloneExe = Join-Path $rootDir "rclone-feishu.exe"
$settingsPath = Join-Path $rootDir "rclone-feishu.settings.json"
$logDir = Join-Path $rootDir "logs"
$startupName = "rclone-feishu-mount.vbs"
$bundledLarkCliDir = Join-Path $rootDir "tools\lark-cli"
$requiredFeishuScopes = "space:document:retrieve drive:file space:document:delete"
$winFspBinDirs = @(
    (Join-Path ${env:ProgramFiles(x86)} "WinFsp\bin"),
    (Join-Path $env:ProgramFiles "WinFsp\bin")
)
$defaultSettings = [ordered]@{
    Backend = "feishu"
    Remote = "Feishu"
    RemotePath = ""
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

function Get-WinFspBinDir {
    foreach ($dir in $winFspBinDirs) {
        if ([string]::IsNullOrWhiteSpace($dir)) {
            continue
        }
        if (Test-Path -LiteralPath (Join-Path $dir "winfsp-x64.dll")) {
            return $dir
        }
    }
    return $null
}

function Initialize-WinFspTools {
    $winFspBin = Get-WinFspBinDir
    if (-not [string]::IsNullOrWhiteSpace($winFspBin)) {
        $paths = @($env:PATH -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($paths -notcontains $winFspBin) {
            $env:PATH = "$winFspBin;$env:PATH"
        }
    }
}

Initialize-BundledTools
Initialize-WinFspTools

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

function Ensure-WinFsp {
    Initialize-WinFspTools
    if (-not [string]::IsNullOrWhiteSpace((Get-WinFspBinDir))) {
        return
    }

    Write-Host "[安装] 当前系统缺少 WinFsp，正在尝试自动安装。"
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "未安装 WinFsp，且未找到 winget。请手动安装 WinFsp：https://winfsp.dev/rel/"
    }

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & winget install --id WinFsp.WinFsp --exact --accept-package-agreements --accept-source-agreements
        $installExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    Initialize-WinFspTools
    if (($installExit -ne 0) -or [string]::IsNullOrWhiteSpace((Get-WinFspBinDir))) {
        throw "WinFsp 自动安装失败。请手动安装 WinFsp 后重新挂载：https://winfsp.dev/rel/"
    }
    Write-Host "[完成] WinFsp 已安装。"
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

function Test-LarkConfig {
    return ((Invoke-LarkCli -CliArgs @("config", "show") -Quiet) -eq 0)
}

function Test-LarkAuth {
    return ((Invoke-LarkCli -CliArgs @("auth", "status", "--json", "--verify") -Quiet) -eq 0)
}

function Test-LarkDriveAccess {
    return ((Invoke-LarkCli -CliArgs @("drive", "files", "list", "--as", "user", "--json") -Quiet) -eq 0)
}

function Test-LarkRequiredScopes {
    return ((Invoke-LarkCli -CliArgs @("auth", "check", "--scope", $requiredFeishuScopes, "--json") -Quiet) -eq 0)
}

function Ensure-LarkLogin {
    if (-not (Get-Command lark-cli -ErrorAction SilentlyContinue)) {
        throw "未找到 lark-cli。安装包可能不完整，请确认 app\tools\lark-cli 存在。"
    }

    Write-Host "[检查] 正在检查飞书 CLI 配置..."
    if (-not (Test-LarkConfig)) {
        Write-Host "[初始化] 首次使用需要初始化飞书登录配置。"
        Write-Host "[提示] 如果命令行显示验证链接，请复制到浏览器完成授权；完成后回到此窗口继续。"
        $initExit = Invoke-LarkCli -CliArgs @("config", "init", "--new", "--brand", "feishu", "--lang", "zh")
        if (($initExit -ne 0) -and -not (Test-LarkConfig)) {
            throw "飞书 CLI 初始化失败"
        }
        if ($initExit -ne 0) {
            Write-Host "[提示] 飞书 CLI 已写入配置，继续登录流程。"
        }
    }

    Write-Host "[检查] 正在验证飞书登录状态..."
    if (-not (Test-LarkAuth)) {
        Write-Host "[登录] 正在打开飞书用户登录..."
        $loginExit = Invoke-LarkCli -CliArgs @("auth", "login", "--domain", "drive", "--domain", "docs", "--scope", $requiredFeishuScopes)
        if (($loginExit -ne 0) -and -not (Test-LarkAuth)) {
            throw "飞书用户登录失败"
        }
        if ($loginExit -ne 0) {
            Write-Host "[提示] 飞书用户登录状态有效，继续挂载流程。"
        }
    }

    Write-Host "[检查] 正在验证飞书云盘必要权限..."
    if (-not (Test-LarkRequiredScopes)) {
        Write-Host "[授权] 当前用户缺少飞书云盘必要权限，正在重新打开飞书授权。"
        $loginExit = Invoke-LarkCli -CliArgs @("auth", "login", "--domain", "drive", "--domain", "docs", "--scope", $requiredFeishuScopes)
        if (($loginExit -ne 0) -and -not (Test-LarkRequiredScopes)) {
            throw "飞书云盘授权失败。请确认授权页面勾选并同意所需权限：$requiredFeishuScopes。"
        }
        if (-not (Test-LarkRequiredScopes)) {
            throw "飞书云盘授权后仍缺少必要权限：$requiredFeishuScopes。"
        }
    }

    Write-Host "[检查] 正在验证飞书云盘访问权限..."
    if (-not (Test-LarkDriveAccess)) {
        Write-Host "[授权] 当前用户缺少飞书云盘访问授权，正在重新打开飞书授权。"
        $loginExit = Invoke-LarkCli -CliArgs @("auth", "login", "--domain", "drive", "--domain", "docs", "--scope", $requiredFeishuScopes)
        if (($loginExit -ne 0) -and -not (Test-LarkDriveAccess)) {
            throw "飞书云盘授权失败。请确认授权页面勾选并同意所需权限：$requiredFeishuScopes。"
        }
        if (-not (Test-LarkDriveAccess)) {
            throw "飞书云盘授权后仍无法访问。请重新运行诊断并查看 lark-cli 与 Feishu 后端列表。"
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

    if ($Backend -ieq "ftp") {
        throw "FTP 连接配置不存在。请在管理器中选择 切换连接类型或盘符 后重新配置 FTP。"
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

function Normalize-RemotePath {
    param([string]$RemotePath)
    if ([string]::IsNullOrWhiteSpace($RemotePath)) {
        return ""
    }
    $RemotePath = $RemotePath.Trim().Replace("\", "/")
    if ($RemotePath -eq "/") {
        return ""
    }
    if (-not $RemotePath.StartsWith("/")) {
        $RemotePath = "/$RemotePath"
    }
    return $RemotePath
}

function Get-RemoteSpec {
    param([pscustomobject]$Settings)
    $remotePath = Normalize-RemotePath $Settings.RemotePath
    if ([string]::IsNullOrWhiteSpace($remotePath)) {
        return "$($Settings.Remote):"
    }
    return "$($Settings.Remote):$remotePath"
}

function Read-RequiredText {
    param([string]$Prompt)
    $value = Read-Host $Prompt
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "$Prompt 不能为空"
    }
    return $value.Trim()
}

function Read-TextWithDefault {
    param([string]$Prompt, [string]$Default)
    $value = Read-Host "$Prompt [默认：$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value.Trim()
}

function Convert-SecureStringToPlainText {
    param([securestring]$SecureString)
    if ($null -eq $SecureString) {
        return ""
    }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Test-RemoteExists {
    param([string]$Remote)
    $list = & $rcloneExe listremotes
    return ($list -contains "${Remote}:")
}

function Configure-FtpRemote {
    param([string]$Remote)

    Write-Host "[配置] 正在配置 FTP 连接 `"$Remote`"。"
    $hostName = Read-RequiredText "请输入 FTP 主机，例如 ftp.example.com"
    $tlsChoice = Read-Host "请选择加密方式：`n1) 普通 FTP`n2) 显式 FTPS`n3) 隐式 FTPS`n[默认：1]"
    if ([string]::IsNullOrWhiteSpace($tlsChoice)) { $tlsChoice = "1" }
    switch ($tlsChoice) {
        "1" { $tls = "false"; $explicitTls = "false"; $defaultPort = "21" }
        "2" { $tls = "false"; $explicitTls = "true"; $defaultPort = "21" }
        "3" { $tls = "true"; $explicitTls = "false"; $defaultPort = "990" }
        default { throw "无效的 FTP 加密方式选择" }
    }
    $port = Read-TextWithDefault "请输入 FTP 端口" $defaultPort
    if ($port -notmatch '^\d+$') {
        throw "FTP 端口必须是数字"
    }
    $user = Read-TextWithDefault "请输入 FTP 用户名" ([Environment]::UserName)
    $securePassword = Read-Host "请输入 FTP 密码；匿名或无密码时直接回车" -AsSecureString
    $plainPassword = Convert-SecureStringToPlainText $securePassword

    $configAction = "create"
    $args = @("config", "create", $Remote, "ftp")
    if (Test-RemoteExists $Remote) {
        $configAction = "update"
        $args = @("config", "update", $Remote)
    }
    $args += @(
        "host", $hostName,
        "user", $user,
        "port", $port,
        "tls", $tls,
        "explicit_tls", $explicitTls,
        "--obscure",
        "--non-interactive"
    )
    if (-not [string]::IsNullOrEmpty($plainPassword)) {
        $args = @("config", $configAction)
        if ($configAction -eq "create") {
            $args += @($Remote, "ftp")
        }
        else {
            $args += @($Remote)
        }
        $args += @(
            "host", $hostName,
            "user", $user,
            "port", $port,
            "pass", $plainPassword,
            "tls", $tls,
            "explicit_tls", $explicitTls,
            "--obscure",
            "--non-interactive"
        )
    }

    try {
        & $rcloneExe @args
        if ($LASTEXITCODE -ne 0) {
            throw "创建或更新 FTP 连接配置失败"
        }
    }
    finally {
        $plainPassword = $null
    }
    Write-Host "[完成] FTP 连接配置已保存。"
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
    if ($settings.Backend -ieq "ftp") {
        Configure-FtpRemote -Remote $settings.Remote
        $settings.RemotePath = Normalize-RemotePath (Read-Host "请输入 FTP 远端目录，例如 / 或 /public，直接回车使用根目录")
    }
    else {
        $settings.RemotePath = ""
    }
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

function Test-MountPointReady {
    $settings = Get-Settings
    $mountPoint = Normalize-MountPoint $settings.MountPoint
    $root = "$mountPoint\"
    try {
        if (-not (Test-Path -LiteralPath $root)) {
            return $false
        }
        $entries = [System.IO.Directory]::EnumerateFileSystemEntries($root)
        $enumerator = $entries.GetEnumerator()
        try {
            $null = $enumerator.MoveNext()
        }
        finally {
            if ($enumerator -is [System.IDisposable]) {
                $enumerator.Dispose()
            }
        }
        return $true
    }
    catch {
        return $false
    }
}

function Get-MountStatusText {
    if (-not (Test-RcOnline)) {
        return "未运行"
    }
    if (Test-MountPointReady) {
        return "运行中"
    }
    return "运行中但盘符不可用"
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

function Get-MountLogFile {
    return (Join-Path $logDir "mount.log")
}

function Reset-MountLog {
    $logFile = Get-MountLogFile
    if (Test-Path -LiteralPath $logFile) {
        Clear-Content -LiteralPath $logFile
    }
}

function Get-MountFailureFromLog {
    $logFile = Get-MountLogFile
    if (-not (Test-Path -LiteralPath $logFile)) {
        return $null
    }
    $failure = Get-Content -LiteralPath $logFile -Tail 80 | Where-Object {
        $_ -match 'CRITICAL|Fatal error|failed to mount|cannot find winfsp'
    } | Select-Object -Last 1
    return $failure
}

function Show-Status {
    $settings = Get-Settings
    Write-Host "连接类型：$($settings.Backend)"
    Write-Host "连接名称：$($settings.Remote)"
    if (-not [string]::IsNullOrWhiteSpace((Normalize-RemotePath $settings.RemotePath))) {
        Write-Host "远端目录：$(Normalize-RemotePath $settings.RemotePath)"
    }
    Write-Host "挂载盘符：$($settings.MountPoint)"
    Write-Host "开机启动：$(if (Test-AutoStartEnabled $settings.AutoStart) { '已启用' } else { '已关闭' })"
    Write-Host "启动项  ：$(if (Test-StartupInstalled) { '已安装' } else { '未安装' })"
    Write-Host "挂载状态：$(Get-MountStatusText)"
}

function Get-MountArgs {
    param([pscustomobject]$Settings)

    $logFile = Get-MountLogFile
    $remoteSpec = Get-RemoteSpec $Settings
    return @(
        "mount", $remoteSpec, $Settings.MountPoint,
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
    Ensure-WinFsp
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
    Ensure-WinFsp
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

    Ensure-Remote -Remote $settings.Remote -Backend $settings.Backend
    if ($settings.Backend -ieq "feishu") {
        Ensure-LarkLogin
    }

    if ((Test-RcOnline) -and (Test-MountPointReady)) {
        Write-Host "[提示] 托管挂载已在运行，连接状态已检查。"
        return
    }
    if (Test-RcOnline) {
        Write-Host "[提示] 检测到后台进程在线但盘符不可用，正在重启挂载。"
        Stop-Mount
        Start-Sleep -Seconds 1
    }

    Reset-MountLog
    Write-Host "[运行] 正在后台将 $(Get-RemoteSpec $settings) 挂载到 $($settings.MountPoint)"
    Start-MountWorkerProcess

    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if ((Test-RcOnline) -and (Test-MountPointReady)) {
            Write-Host "[完成] 挂载已在后台运行，可以关闭此窗口。"
            return
        }
        $failure = Get-MountFailureFromLog
        if (-not [string]::IsNullOrWhiteSpace($failure)) {
            throw "挂载失败：$failure"
        }
    }

    $failure = Get-MountFailureFromLog
    if (-not [string]::IsNullOrWhiteSpace($failure)) {
        throw "挂载失败：$failure"
    }

    throw "后台挂载进程已启动，但盘符 $($settings.MountPoint) 仍不可访问。日志位置：$(Join-Path $logDir 'mount.log')"
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

function Invoke-DiagnosticCommand {
    param(
        [string]$Title,
        [scriptblock]$Command
    )

    Write-Host ""
    Write-Host "[$Title]"
    try {
        & $Command
        if ($LASTEXITCODE -ne $null) {
            Write-Host "退出码：$LASTEXITCODE"
        }
    }
    catch {
        Write-Host "异常：$($_.Exception.Message)"
    }
}

function Show-Diagnostics {
    $settings = Get-Settings
    $mountPoint = Normalize-MountPoint $settings.MountPoint
    $mountRoot = "$mountPoint\"
    $logFile = Get-MountLogFile

    Write-Host "===== rclone-feishu 诊断 ====="
    Write-Host "程序目录：$rootDir"
    Write-Host "rclone ：$rcloneExe"
    Write-Host "连接类型：$($settings.Backend)"
    Write-Host "连接名称：$($settings.Remote)"
    Write-Host "远端目录：$(if ([string]::IsNullOrWhiteSpace((Normalize-RemotePath $settings.RemotePath))) { '/' } else { Normalize-RemotePath $settings.RemotePath })"
    Write-Host "挂载盘符：$mountPoint"
    Write-Host "RC 地址 ：$($settings.RcAddr)"
    Write-Host "启动项  ：$(if (Test-StartupInstalled) { '已安装' } else { '未安装' })"
    Write-Host "挂载状态：$(Get-MountStatusText)"

    Invoke-DiagnosticCommand "WinFsp" {
        $winFspBin = Get-WinFspBinDir
        Write-Host "WinFsp bin：$(if ($winFspBin) { $winFspBin } else { '未找到' })"
        Write-Host "当前 PATH 中 WinFsp："
        $env:PATH -split ';' | Where-Object { $_ -like '*WinFsp*' } | ForEach-Object { Write-Host "  $_" }
        if ($winFspBin) {
            Get-ChildItem -LiteralPath $winFspBin -Filter 'winfsp-*.dll' | Select-Object Name,Length | Format-Table -AutoSize
        }
    }

    if ($settings.Backend -ieq "feishu") {
        Invoke-DiagnosticCommand "lark-cli" {
            $cmd = Get-Command lark-cli -ErrorAction SilentlyContinue
            Write-Host "lark-cli：$(if ($cmd) { $cmd.Source } else { '未找到' })"
            $null = Invoke-LarkCli -CliArgs @("--version")
            Write-Host "config show：$(if (Test-LarkConfig) { '成功' } else { '失败' })"
            Write-Host "auth status --verify：$(if (Test-LarkAuth) { '成功' } else { '失败' })"
            Write-Host "必要权限：$(if (Test-LarkRequiredScopes) { '成功' } else { '失败' })"
            Write-Host "权限列表：$requiredFeishuScopes"
            Write-Host "drive files list：$(if (Test-LarkDriveAccess) { '成功' } else { '失败' })"
        }
    }

    Invoke-DiagnosticCommand "rclone" {
        Ensure-Rclone
        & $rcloneExe version
        & $rcloneExe listremotes
    }

    Invoke-DiagnosticCommand "远端列表" {
        & $rcloneExe lsjson (Get-RemoteSpec $settings) --max-depth 1 --low-level-retries 1 --retries 1
    }

    Invoke-DiagnosticCommand "RC 状态" {
        & $rcloneExe rc --rc-addr $settings.RcAddr --rc-no-auth core/stats
    }

    Invoke-DiagnosticCommand "盘符访问" {
        Write-Host "Test-Path ${mountRoot}：$(Test-Path -LiteralPath $mountRoot)"
        if (Test-Path -LiteralPath $mountRoot) {
            Get-ChildItem -LiteralPath $mountRoot -Force | Select-Object -First 20 Mode,Length,Name,LastWriteTime | Format-Table -AutoSize
        }
    }

    Invoke-DiagnosticCommand "mount.log 最近 120 行" {
        if (Test-Path -LiteralPath $logFile) {
            Get-Content -LiteralPath $logFile -Tail 120
        }
        else {
            Write-Host "日志不存在：$logFile"
        }
    }
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
        $choice = Read-Host "1) 挂载 / 启动`n2) 切换连接类型或盘符`n3) 启用开机启动`n4) 关闭开机启动`n5) 立即刷新缓存`n6) 停止挂载`n7) 打开 rclone 高级配置`n8) 卸载`n9) 诊断`n0) 退出`n请选择"
        switch ($choice) {
            "1" { Start-Mount -Interactive:$false -AllowConfigure:$true; return }
            "2" { Stop-Mount; Start-Mount -Interactive:$true -AllowConfigure:$true; return }
            "3" { Install-Startup }
            "4" { Remove-Startup }
            "5" { Refresh-Cache }
            "6" { Stop-Mount }
            "7" { Open-RcloneConfig }
            "8" { Uninstall-Package; return }
            "9" { Show-Diagnostics }
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
        "Diagnose" { Show-Diagnostics; exit 0 }
    }
}
catch {
    Write-Host "[错误] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
