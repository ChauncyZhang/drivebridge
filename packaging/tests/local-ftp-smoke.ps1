param(
    [string]$RcloneExe = "",
    [int]$Port = 52121,
    [string]$User = "drivebridge",
    [string]$Password = "drivebridge-test"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "..\..")

if ([string]::IsNullOrWhiteSpace($RcloneExe)) {
    $candidate = Join-Path $repoRoot "rclone-feishu-cmount.exe"
    if (Test-Path -LiteralPath $candidate) {
        $RcloneExe = $candidate
    }
    else {
        $buildOut = Join-Path $repoRoot "dist\drivebridge-test.exe"
        New-Item -ItemType Directory -Path (Split-Path -Parent $buildOut) -Force | Out-Null
        Push-Location $repoRoot
        try {
            & go build -trimpath -o $buildOut .
            if ($LASTEXITCODE -ne 0) {
                throw "go build failed"
            }
        }
        finally {
            Pop-Location
        }
        $RcloneExe = $buildOut
    }
}

if (-not (Test-Path -LiteralPath $RcloneExe)) {
    throw "rclone executable not found: $RcloneExe"
}

$workDir = Join-Path ([IO.Path]::GetTempPath()) ("drivebridge-ftp-smoke-" + [guid]::NewGuid().ToString("N"))
$ftpRoot = Join-Path $workDir "ftp-root"
$clientDir = Join-Path $workDir "client"
$configFile = Join-Path $workDir "rclone.conf"
$serverLog = Join-Path $workDir "ftp-server.log"
$remoteName = "DriveBridgeLocalFtpSmoke"
$success = $false

New-Item -ItemType Directory -Path $ftpRoot, $clientDir | Out-Null
Set-Content -LiteralPath (Join-Path $ftpRoot "server-seed.txt") -Encoding ascii -Value "seed-from-ftp-server"
Set-Content -LiteralPath (Join-Path $clientDir "upload.txt") -Encoding ascii -Value "upload-from-drivebridge"

function Invoke-IsolatedRclone {
    param([string[]]$Arguments)
    $env:RCLONE_CONFIG = $configFile
    & $RcloneExe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "rclone failed: $($Arguments -join ' ')"
    }
}

function Test-PortOpen {
    param([int]$TargetPort)
    $client = New-Object Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect("127.0.0.1", $TargetPort, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(300)) {
            return $false
        }
        $client.EndConnect($iar)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

$server = $null
try {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $RcloneExe
    $psi.Arguments = "serve ftp `"$ftpRoot`" --addr 127.0.0.1:$Port --user `"$User`" --pass `"$Password`" --passive-port 52200-52220 --log-file `"$serverLog`" --log-level INFO"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.Environment["RCLONE_CONFIG"] = $configFile
    $server = [Diagnostics.Process]::Start($psi)

    $ready = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        if ($server.HasExited) {
            throw "FTP server exited early. Log: $serverLog"
        }
        if (Test-PortOpen $Port) {
            $ready = $true
            break
        }
    }
    if (-not $ready) {
        throw "FTP server did not open 127.0.0.1:$Port. Log: $serverLog"
    }

    Invoke-IsolatedRclone -Arguments @("config", "create", $remoteName, "ftp", "host", "127.0.0.1", "user", $User, "port", "$Port", "pass", $Password, "--obscure", "--non-interactive")

    $list = & $RcloneExe "--config" $configFile "lsf" "${remoteName}:"
    if ($LASTEXITCODE -ne 0 -or ($list -notcontains "server-seed.txt")) {
        throw "FTP list did not include server-seed.txt"
    }

    Invoke-IsolatedRclone -Arguments @("mkdir", "${remoteName}:subdir")
    Invoke-IsolatedRclone -Arguments @("copyto", (Join-Path $clientDir "upload.txt"), "${remoteName}:subdir/upload.txt")

    $downloaded = & $RcloneExe "--config" $configFile "cat" "${remoteName}:subdir/upload.txt"
    if ($LASTEXITCODE -ne 0 -or (($downloaded -join "`n").Trim() -ne "upload-from-drivebridge")) {
        throw "FTP uploaded file content mismatch"
    }

    Invoke-IsolatedRclone -Arguments @("deletefile", "${remoteName}:subdir/upload.txt")
    if (Test-Path -LiteralPath (Join-Path $ftpRoot "subdir\upload.txt")) {
        throw "FTP delete did not remove uploaded file"
    }

    Write-Host "[OK] Local FTP smoke test passed."
    $success = $true
}
finally {
    if ($null -ne $server -and -not $server.HasExited) {
        $server.Kill()
        $server.WaitForExit()
    }
    if ($success -and (Test-Path -LiteralPath $workDir)) {
        Remove-Item -LiteralPath $workDir -Recurse -Force
    }
    elseif (-not $success) {
        Write-Host "[INFO] Test failed; temporary directory kept: $workDir"
    }
}
