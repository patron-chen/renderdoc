<#
.SYNOPSIS
    RenderDoc Android 目标应用注入清理/还原脚本
.DESCRIPTION
    清理 Android 系统的全局 GPU Debug Layers 设置并移除 ADB 端口转发，恢复系统默认渲染状态。
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, HelpMessage = "可选：指定的 ADB 设备 ID")]
    [string]$DeviceId = "",

    [Parameter(HelpMessage = "通信端口，默认 38920")]
    [int]$Port = 38920
)

# 确保输出使用 UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Exec-Adb
{
    param([string]$ArgsStr)
    $cmdPrefix = "adb"
    if (![string]::IsNullOrEmpty($DeviceId))
    {
        $cmdPrefix = "adb -s $DeviceId"
    }
    $output = cmd.exe /c "$cmdPrefix $ArgsStr 2>&1"
    return ($output | Out-String).Trim()
}

function Exec-Su
{
    param([string]$CmdStr)
    $cmdPrefix = "adb"
    if (![string]::IsNullOrEmpty($DeviceId))
    {
        $cmdPrefix = "adb -s $DeviceId"
    }
    $b64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($CmdStr))
    $output = cmd.exe /c "$cmdPrefix shell `"su -c 'echo $b64 | base64 -d | sh'`" 2>&1"
    return ($output | Out-String).Trim()
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " [RenderDoc] 清理 Android GPU Debug Layer 设置" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

Write-Host "`n[1/3] 清除 Android 系统 GPU Debug Layers 配置..." -ForegroundColor Green
Exec-Su "settings delete global enable_gpu_debug_layers" | Out-Null
Exec-Su "settings delete global gpu_debug_app" | Out-Null
Exec-Su "settings delete global gpu_debug_layer_app" | Out-Null
Exec-Su "settings delete global gpu_debug_layers" | Out-Null
Exec-Su "settings delete global gpu_debug_layers_gles" | Out-Null
Exec-Su "setprop debug.rdoc.IGNORE_LAYERS 0" | Out-Null
Write-Host "      系统 GPU Debug Layers 设置已清除。" -ForegroundColor Gray

Write-Host "`n[2/3] 移除 ADB 端口转发 (tcp:$Port)..." -ForegroundColor Green
Exec-Adb "forward --remove tcp:$Port" | Out-Null
Write-Host "      ADB 端口转发已移除。" -ForegroundColor Gray

Write-Host "`n[3/3] 恢复 SELinux 状态 (可选)..." -ForegroundColor Green
# 注：保持 permissive 或恢复由用户决定，此处可保留或设为 1
Write-Host "      如需恢复 SELinux 强制模式可手动执行: adb shell su -c setenforce 1" -ForegroundColor Gray

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host " [完成] 手机 GPU 调试状态已完全还原！" -ForegroundColor Green
Write-Host "==========================================================`n" -ForegroundColor Green
