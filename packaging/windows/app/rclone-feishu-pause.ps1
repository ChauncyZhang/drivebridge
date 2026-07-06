param(
    [int]$ExitCode = 0
)

Write-Host ""
if ($ExitCode -ne 0) {
    Write-Host "运行失败，错误码：$ExitCode" -ForegroundColor Red
}
else {
    Write-Host "操作已结束。"
}
Read-Host "按回车键关闭此窗口" | Out-Null
exit $ExitCode
