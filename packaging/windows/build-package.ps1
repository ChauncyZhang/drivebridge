param(
    [string]$RcloneExe = "",
    [string]$OutputDir = "",
    [switch]$Zip
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "..\..")
if ([string]::IsNullOrWhiteSpace($RcloneExe)) {
    $RcloneExe = Join-Path $repoRoot "rclone-feishu.exe"
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot "dist\rclone-feishu-windows-amd64"
}

function Resolve-CommandPath($name) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $cmd) {
        return $null
    }
    return $cmd.Source
}

function Copy-CleanDirectory($source, $destination) {
    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination -Recurse -Force
    }
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
}

if (-not (Test-Path -LiteralPath $RcloneExe)) {
    throw "rclone executable not found: $RcloneExe"
}

$larkCmd = Resolve-CommandPath "lark-cli.cmd"
if ($null -eq $larkCmd) {
    $larkCmd = Resolve-CommandPath "lark-cli"
}
if ($null -eq $larkCmd) {
    throw "lark-cli is required for packaging. Install it first: npm install -g @larksuite/cli"
}

$nodeExe = Resolve-CommandPath "node.exe"
if ($null -eq $nodeExe) {
    throw "node.exe is required for packaging because bundled lark-cli runs through Node.js."
}

$npmPrefix = Split-Path -Parent $larkCmd
$larkPackage = Join-Path $npmPrefix "node_modules\@larksuite\cli"
if (-not (Test-Path -LiteralPath $larkPackage)) {
    throw "Cannot locate @larksuite/cli package next to $larkCmd"
}

$larkBinary = Join-Path $larkPackage "bin\lark-cli.exe"
if (-not (Test-Path -LiteralPath $larkBinary)) {
    throw "Cannot locate bundled lark-cli native binary: $larkBinary"
}

if (Test-Path -LiteralPath $OutputDir) {
    Remove-Item -LiteralPath $OutputDir -Recurse -Force
}
New-Item -ItemType Directory -Path $OutputDir | Out-Null

$launcher = Get-ChildItem -LiteralPath $scriptDir -Filter "*.cmd" -File | Select-Object -First 1
if ($null -eq $launcher) {
    throw "Cannot locate the root launcher .cmd under $scriptDir"
}
Copy-Item -LiteralPath $launcher.FullName -Destination $OutputDir -Force

$appOut = Join-Path $OutputDir "app"
New-Item -ItemType Directory -Path $appOut | Out-Null
Get-ChildItem -LiteralPath (Join-Path $scriptDir "app") -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $appOut -Recurse -Force
}
Copy-Item -LiteralPath $RcloneExe -Destination (Join-Path $appOut "rclone-feishu.exe") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "COPYING") -Destination (Join-Path $appOut "LICENSE.rclone.txt") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "NOTICE.md") -Destination $appOut -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "THIRD_PARTY_NOTICES.md") -Destination $appOut -Force

$toolsOut = Join-Path $appOut "tools\lark-cli"
New-Item -ItemType Directory -Path $toolsOut | Out-Null
Copy-Item -LiteralPath $larkCmd -Destination (Join-Path $toolsOut "lark-cli.cmd") -Force
$larkPs1 = [System.IO.Path]::ChangeExtension($larkCmd, ".ps1")
if (Test-Path -LiteralPath $larkPs1) {
    Copy-Item -LiteralPath $larkPs1 -Destination (Join-Path $toolsOut "lark-cli.ps1") -Force
}
$larkShim = Join-Path $npmPrefix "lark-cli"
if (Test-Path -LiteralPath $larkShim) {
    Copy-Item -LiteralPath $larkShim -Destination (Join-Path $toolsOut "lark-cli") -Force
}
Copy-Item -LiteralPath $nodeExe -Destination (Join-Path $toolsOut "node.exe") -Force
Copy-CleanDirectory $larkPackage (Join-Path $toolsOut "node_modules\@larksuite\cli")
Copy-Item -LiteralPath (Join-Path $larkPackage "LICENSE") -Destination (Join-Path $appOut "LICENSE.lark-cli.txt") -Force

$nodeVersionText = (& $nodeExe --version).TrimStart("v")
$nodeMajorMinorPatch = ($nodeVersionText -split "\.")[0..2] -join "."
$nodeLicenseOut = Join-Path $appOut "LICENSE.nodejs.txt"
$nodeLicenseUrl = "https://raw.githubusercontent.com/nodejs/node/v$nodeMajorMinorPatch/LICENSE"
Invoke-WebRequest -Uri $nodeLicenseUrl -OutFile $nodeLicenseOut

New-Item -ItemType Directory -Path (Join-Path $appOut "logs") | Out-Null

if ($Zip) {
    $zipPath = "$OutputDir.zip"
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $OutputDir "*") -DestinationPath $zipPath -Force
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath
    "$($hash.Hash.ToLower())  $(Split-Path -Leaf $zipPath)" | Set-Content -LiteralPath "$zipPath.sha256.txt" -Encoding ascii
}

Write-Host "Windows package created: $OutputDir"
