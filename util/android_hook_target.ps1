<#
.SYNOPSIS
    RenderDoc Android 目标应用免 Launch 注入配置脚本 (支持 Magisk Root)
.DESCRIPTION
    配置 Android 系统原生 GPU Debug Layers (Vulkan + OpenGL ES)，使目标 App 可以在手机上手动直接打开，
    自动挂载 RenderDoc 抓包 Layer，并在 PC 端 RenderDoc 中通过 'Attach to Running Instance' 直接连接。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, HelpMessage = "目标应用的 Android 包名 (例如 com.example.game)")]
    [string]$PackageName,

    [Parameter(Position = 1, HelpMessage = "可选：指定的 ADB 设备 ID")]
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
Write-Host " [RenderDoc] Android 目标应用全局 Hook 注入配置向导" -ForegroundColor Cyan
Write-Host " 目标包名: $PackageName" -ForegroundColor Yellow
Write-Host " 通信端口: $Port" -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. 检查 ADB 设备连通性
Write-Host "`n[1/7] 检查 ADB 设备连接状态..." -ForegroundColor Green
$devicesOutput = Exec-Adb "devices"
if ($devicesOutput -notmatch "(?m)^[a-zA-Z0-9._:-]+\s+device$")
{
    Write-Error "[-] 未检测到已授权的 ADB 设备。请检查 USB 调试是否开启并连接好设备。"
    exit 1
}
Write-Host "      ADB 设备连接正常。" -ForegroundColor Gray

# 2. 检查 Magisk / Root 权限
Write-Host "`n[2/7] 验证 Root (su) 权限..." -ForegroundColor Green
$rootId = Exec-Su "id"
if ($rootId -notmatch "uid=0")
{
    Write-Error "[-] 无法获取 Root 权限。请在手机 Magisk 中授予 Shell / ADB root 权限。"
    exit 1
}
Write-Host "      Root 权限验证通过: $rootId" -ForegroundColor Gray

# 3. 检测设备 CPU 架构 (ABI) 并匹配 Layer APK
Write-Host "`n[3/7] 检测设备 ABI 架构与 RenderDoc Layer APK..." -ForegroundColor Green
$abi = Exec-Adb "shell getprop ro.product.cpu.abi"
$layerPackage = "org.renderdoc.renderdoccmd.arm64"
$apkFilename = "org.renderdoc.renderdoccmd.arm64.apk"
if ($abi -like "*arm*32*" -or $abi -eq "armeabi-v7a")
{
    $layerPackage = "org.renderdoc.renderdoccmd.arm32"
    $apkFilename = "org.renderdoc.renderdoccmd.arm32.apk"
}
Write-Host "      设备架构: $abi, 对应 Layer 宿主包名: $layerPackage" -ForegroundColor Gray

# 检查 Layer APK 是否已安装
$pkgCheck = Exec-Adb "shell pm path $layerPackage"
if ($pkgCheck -notmatch "package:")
{
    Write-Warning "[!] 手机未安装 RenderDoc Layer 宿主 APK ($layerPackage)。"
    Write-Host "    正在尝试从本地工程寻找 APK 并自动安装..." -ForegroundColor Yellow

    # 优先查找本地编译输出目录
    $searchPaths = @(
        "$PSScriptRoot\..\x64\Development\plugins\android\$apkFilename",
        "$PSScriptRoot\..\x64\Release\plugins\android\$apkFilename",
        "$PSScriptRoot\..\build-android-release-arm64\bin\$apkFilename",
        "$PSScriptRoot\..\build-android-arm64\bin\$apkFilename"
    )

    $foundApk = $null
    foreach ($p in $searchPaths)
    {
        if (Test-Path $p)
        {
            $foundApk = (Resolve-Path $p).Path
            break
        }
    }

    if ($foundApk)
    {
        Write-Host "    找到 APK: $foundApk" -ForegroundColor Gray
        Write-Host "    正在推送到手机安装..." -ForegroundColor Yellow
        $installRes = Exec-Adb "install -r -g `"$foundApk`""
        Write-Host "    安装结果: $installRes" -ForegroundColor Gray
    }
    else
    {
        Write-Warning "[-] 未在本地找到预编译的 $apkFilename。请先使用 build_android_apks.bat 编译并安装该 APK。"
    }
}
else
{
    Write-Host "      RenderDoc Layer 宿主 APK 已安装在手机上。" -ForegroundColor Gray
}

# 4. 配置 ro.debuggable 与 SELinux
Write-Host "`n[4/7] 提升系统调试权限 (ro.debuggable & SELinux Permissive)..." -ForegroundColor Green
# 利用 Magisk resetprop 动态修改系统只读属性 (无需重启)
Exec-Su "resetprop ro.debuggable 1 || magisk resetprop ro.debuggable 1 || setprop ro.debuggable 1" | Out-Null
Exec-Su "resetprop ro.force.debuggable 1 || magisk resetprop ro.force.debuggable 1 || setprop ro.force.debuggable 1" | Out-Null
# 关闭 SELinux 强制限制，避免目标 App 无法读取外部 Layer so
Exec-Su "setenforce 0" | Out-Null
# 保持屏幕常亮
Exec-Su "svc power stayon true" | Out-Null

$debuggableVal = Exec-Adb "shell getprop ro.debuggable"
Write-Host "      当前 ro.debuggable: $debuggableVal, SELinux: Permissive" -ForegroundColor Gray

# 5. 配置文件与存储权限 (RenderDoc 抓帧存储目录)
Write-Host "`n[5/7] 配置目标 App 存储权限与目录..." -ForegroundColor Green
Exec-Su "appops set $PackageName MANAGE_EXTERNAL_STORAGE allow 2>/dev/null" | Out-Null
Exec-Su "appops set $layerPackage MANAGE_EXTERNAL_STORAGE allow 2>/dev/null" | Out-Null
# 确保在 /sdcard/Android/data/<pkg>/files/ 存在并有读写权限
Exec-Su "mkdir -p /sdcard/Android/data/$PackageName/files" | Out-Null
Exec-Su "chmod -R 777 /sdcard/Android/data/$PackageName" | Out-Null
Write-Host "      存储目录配置完成。" -ForegroundColor Gray

# 6. 配置 Android 系统的全局 GPU Debug Layers (Vulkan + OpenGL ES)
Write-Host "`n[6/7] 配置 Android 系统 GPU Debug Layers (Vulkan + GLES)..." -ForegroundColor Green
Exec-Su "settings put global enable_gpu_debug_layers 1" | Out-Null
Exec-Su "settings put global gpu_debug_app $PackageName" | Out-Null
Exec-Su "settings put global gpu_debug_layer_app $layerPackage" | Out-Null
Exec-Su "settings put global gpu_debug_layers VK_LAYER_RENDERDOC_Capture" | Out-Null
Exec-Su "settings put global gpu_debug_layers_gles libVkLayer_GLES_RenderDoc.so" | Out-Null
Exec-Su "setprop debug.rdoc.IGNORE_LAYERS 0" | Out-Null

Write-Host "      enable_gpu_debug_layers: 1" -ForegroundColor Gray
Write-Host "      gpu_debug_app          : $PackageName" -ForegroundColor Gray
Write-Host "      gpu_debug_layer_app    : $layerPackage" -ForegroundColor Gray
Write-Host "      gpu_debug_layers (VK)  : VK_LAYER_RENDERDOC_Capture" -ForegroundColor Gray
Write-Host "      gpu_debug_layers (GLES): libVkLayer_GLES_RenderDoc.so" -ForegroundColor Gray

# 7. 配置 ADB 端口转发
Write-Host "`n[7/7] 配置 ADB 端口转发 (tcp:$Port -> tcp:$Port)..." -ForegroundColor Green
Exec-Adb "forward tcp:$Port tcp:$Port" | Out-Null
$forwardList = Exec-Adb "forward --list"
Write-Host "      当前端口转发列表:" -ForegroundColor Gray
Write-Host "      $forwardList" -ForegroundColor Gray

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host " [成功] 目标应用注入环境已准备就绪！" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "使用步骤:" -ForegroundColor White
Write-Host " 1. 拿起手机，在手机桌面上像往常一样正常点击打开你的游戏/应用 ($PackageName)" -ForegroundColor Yellow
Write-Host " 2. 打开 PC 上的 RenderDoc 客户端" -ForegroundColor Yellow
Write-Host " 3. 点击顶部菜单栏: [File] -> [Attach to Running Instance]" -ForegroundColor Yellow
Write-Host " 4. 在列表中双击连接 'localhost:$Port' (或手动在 Host 输入框填 localhost:$Port 后点击 Connect)" -ForegroundColor Yellow
Write-Host " 5. 连接成功后即可像平常一样按 F12 或点击 'Capture Frame' 抓帧！" -ForegroundColor Yellow
Write-Host " 6. 调试完成后，运行 .\android_unhook.ps1 清理系统 Layer 环境变量。" -ForegroundColor White
Write-Host "==========================================================`n" -ForegroundColor Green
