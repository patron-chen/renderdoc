# RenderDoc Android Hook 管理入口 (支持命令行参数与交互式菜单)
param(
    [string]$ActionOrPackage = "",
    [string]$DeviceId = "",
    [int]$Port = 38920
)

# 兼容处理原生传入的 -h / --help / help / -u 等任意标志
if ($args.Count -gt 0 -and [string]::IsNullOrEmpty($ActionOrPackage))
{
    $ActionOrPackage = $args[0]
}


[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$targetScript = Join-Path $PSScriptRoot "android_hook_target.ps1"
$unhookScript = Join-Path $PSScriptRoot "android_unhook.ps1"

function Show-Help
{
    Write-Host "`n用法:" -ForegroundColor Cyan
    Write-Host "  .\android_hook.bat <包名>       直接为目标 App 配置注入"
    Write-Host "  .\android_hook.bat unhook     清理还原手机 GPU Layer 设置"
    Write-Host "  .\android_hook.bat fix-debug  一键写入 Magisk 开机脚本固化 ro.debuggable 解决无日志"
    Write-Host "  .\android_hook.bat -u         同 unhook"
    Write-Host "  .\android_hook.bat            打开交互式菜单`n"
}

function Set-PersistentDebuggable
{
    Write-Host "`n[+] 正在为 Magisk 配置 post-fs-data 开机启动脚本 (解决 Release 游戏不加载 Layer)..." -ForegroundColor Cyan

    $cmdPrefix = "adb"
    if (![string]::IsNullOrEmpty($DeviceId)) { $cmdPrefix = "adb -s $DeviceId" }

    # 直接使用 Base64 编码的 shell 脚本在 root 下执行，彻底避开 Windows cmd 的引号脱落与 && 提权降级问题
    $shScript = @"
mkdir -p /data/adb/post-fs-data.d
cat << 'EOF' > /data/adb/post-fs-data.d/debuggable.sh
#!/system/bin/sh
# 确保在 Zygote 启动前强制固化 ro.debuggable
resetprop ro.debuggable 1
resetprop ro.force.debuggable 1
EOF
chmod 755 /data/adb/post-fs-data.d/debuggable.sh
ls -l /data/adb/post-fs-data.d/debuggable.sh
"@

    $b64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($shScript))

    Write-Host "    [1/2] 正在通过 Root 权限直接写入 /data/adb/post-fs-data.d/debuggable.sh..." -ForegroundColor Gray
    $check = (cmd.exe /c "$cmdPrefix shell `"su -c 'echo $b64 | base64 -d | sh'`"" 2>&1 | Out-String).Trim()

    if ($check -match "debuggable\.sh")
    {
        Write-Host "    [2/2] 验证安装成功:" -ForegroundColor Green
        Write-Host "          $check" -ForegroundColor Gray
    }
    else
    {
        # 如果 base64 不可用，降级为逐行独立 su 执行
        Write-Warning "[-] Base64 方式写入未返回预期结果，尝试降级逐行 root 写入..."
        cmd.exe /c "$cmdPrefix shell `"su -c 'mkdir -p /data/adb/post-fs-data.d'`"" | Out-Null
        cmd.exe /c "$cmdPrefix shell `"su -c 'echo resetprop ro.debuggable 1 > /data/adb/post-fs-data.d/debuggable.sh'`"" | Out-Null
        cmd.exe /c "$cmdPrefix shell `"su -c 'echo resetprop ro.force.debuggable 1 >> /data/adb/post-fs-data.d/debuggable.sh'`"" | Out-Null
        cmd.exe /c "$cmdPrefix shell `"su -c 'chmod 755 /data/adb/post-fs-data.d/debuggable.sh'`"" | Out-Null
        $check = (cmd.exe /c "$cmdPrefix shell `"su -c 'ls -l /data/adb/post-fs-data.d/debuggable.sh'`"" 2>&1 | Out-String).Trim()
        Write-Host "          $check" -ForegroundColor Gray
    }

    if ($check -notmatch "debuggable\.sh")
    {
        Write-Error "[-] 写入失败，请检查 Magisk 授予权限。返回: $check"
        return
    }

    Write-Host "`n==========================================================" -ForegroundColor Green
    Write-Host " [成功] Magisk 开机脚本已安装完成！" -ForegroundColor Green
    Write-Host " 手机现在需要重启一次，确保 Zygote 开机时即处于 Debuggable 状态。" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Green
    $reboot = Read-Host "是否现在自动重启手机？(Y/N，默认 Y)"
    if ($reboot -ne "N" -and $reboot -ne "n")
    {
        Write-Host "正在重启手机..." -ForegroundColor Yellow
        cmd.exe /c "$cmdPrefix reboot" | Out-Null
        Write-Host "手机正在重启，请等待开机完成后直接运行: .\android_hook.bat <你的包名>" -ForegroundColor White
    }
}

# 1. 检查命令行参数
if ($ActionOrPackage -match "^(-h|--help|help|/\?)$")
{
    Show-Help
    exit 0
}

if ($ActionOrPackage -match "^(fix-debug|fix|boot-debug)$")
{
    Set-PersistentDebuggable
    exit 0
}

if ($ActionOrPackage -match "^(-u|unhook|clean)$")
{
    & $unhookScript -DeviceId $DeviceId -Port $Port
    exit $LASTEXITCODE
}

if (![string]::IsNullOrEmpty($ActionOrPackage))
{
    & $targetScript -PackageName $ActionOrPackage -DeviceId $DeviceId -Port $Port
    exit $LASTEXITCODE
}

# 2. 交互式菜单 (无参数时)
while ($true)
{
    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "      RenderDoc Android Root Hook 管理工具 (Magisk)       " -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host " [1] 注入并配置目标应用 (Hook Target App)" -ForegroundColor White
    Write-Host " [2] 清除 Hook 设置并还原系统 (Unhook / Reset)" -ForegroundColor White
    Write-Host " [3] 固化全局 Debuggable 解决无日志 (安装 Magisk 开机脚本并重启)" -ForegroundColor White
    Write-Host " [0] 退出 (Exit)" -ForegroundColor White
    Write-Host "==========================================================" -ForegroundColor Cyan

    $choice = Read-Host "请选择操作编号 [0-3]"
    switch ($choice)
    {
        "1"
        {
            Write-Host ""
            $pkg = Read-Host "请输入目标 App 包名 (例如 com.example.game)"
            if ([string]::IsNullOrWhiteSpace($pkg))
            {
                Write-Warning "包名不能为空！"
                Start-Sleep -Seconds 1
                continue
            }
            & $targetScript -PackageName $pkg.Trim() -DeviceId $DeviceId -Port $Port
            Write-Host "`n按任意键返回主菜单..." -ForegroundColor Gray
            [Console]::ReadKey($true) | Out-Null
        }
        "2"
        {
            Write-Host ""
            & $unhookScript -DeviceId $DeviceId -Port $Port
            Write-Host "`n按任意键返回主菜单..." -ForegroundColor Gray
            [Console]::ReadKey($true) | Out-Null
        }
        "3"
        {
            Set-PersistentDebuggable
            Write-Host "`n按任意键返回主菜单..." -ForegroundColor Gray
            [Console]::ReadKey($true) | Out-Null
        }
        "0"
        {
            exit 0
        }
        default
        {
            Write-Warning "无效输入，请重新输入。"
            Start-Sleep -Seconds 1
        }
    }
}
