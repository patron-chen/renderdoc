<#
.SYNOPSIS
Generates and builds stripped RenderDoc Android APKs on Windows.

.DESCRIPTION
Creates separate MinGW CMake projects for arm32 and arm64, builds Release APKs,
verifies their signatures, and copies them beside the Windows Development build.

.EXAMPLE
.\build_android_apks.ps1

.EXAMPLE
.\build_android_apks.ps1 arm64 -Jobs 8

.EXAMPLE
.\build_android_apks.ps1 all -ConfigureOnly
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('all', 'arm32', 'arm64')]
    [string]$Abi = 'all',

    [switch]$ConfigureOnly,
    [switch]$NoCopy,

    [ValidateRange(1, 256)]
    [int]$Jobs = [Environment]::ProcessorCount,

    [string]$AndroidSdk,
    [string]$AndroidNdk,
    [string]$JdkHome,
    [string]$Java8Home,
    [string]$BuildToolsVersion = '26.0.1',
    [string]$AndroidPlatform = 'android-23',
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Show-Usage {
    @'
Build RenderDoc Android APKs for Windows development builds.

Usage:
  build_android_apks.ps1 [all|arm32|arm64] [options]

Options:
  -ConfigureOnly        Generate CMake projects without building.
  -NoCopy               Do not copy APKs to x64\Development\plugins\android.
  -Jobs N               Parallel build jobs. Default: processor count.
  -AndroidSdk PATH      Android SDK root.
  -AndroidNdk PATH      Android NDK root.
  -JdkHome PATH         JDK containing javac, jar and keytool.
  -Java8Home PATH       Java 8 JRE/JDK used by dx and apksigner.
  -BuildToolsVersion V  Android build-tools version. Default: 26.0.1.
  -AndroidPlatform P    Android platform. Default: android-23.

Examples:
  .\build_android_apks.ps1
  .\build_android_apks.ps1 arm64
  .\build_android_apks.ps1 all -ConfigureOnly
  .\build_android_apks.ps1 all -Jobs 8 -NoCopy
'@ | Write-Host
}

function Get-FirstDirectory {
    param([string[]]$Candidates)

    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Require-File {
    param(
        [string]$Path,
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description not found: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$Description
    )

    Write-Host "==> $Description"
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE"
    }
}

function Get-JavaVersionText {
    param([string]$JavaExecutable)

    $savedErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell converts native stderr into error records when Stop is active.
        $ErrorActionPreference = 'Continue'
        return (& $JavaExecutable -version 2>&1 | Out-String)
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
}

function Find-Java8Home {
    param([string]$ExplicitHome)

    $candidate = Get-FirstDirectory @($ExplicitHome, $env:JAVA8_HOME)
    if ($candidate) {
        return $candidate
    }

    $javaCommand = Get-Command java.exe -ErrorAction SilentlyContinue
    if (-not $javaCommand) {
        return $null
    }

    $versionText = Get-JavaVersionText $javaCommand.Source
    if ($versionText -notmatch 'version "1\.8\.') {
        return $null
    }

    $javaItem = Get-Item -LiteralPath $javaCommand.Source -Force
    $javaPath = $javaItem.FullName
    if ($javaItem.PSObject.Properties['LinkType'] -and $javaItem.LinkType -and $javaItem.Target) {
        $javaPath = [string]$javaItem.Target
    }

    return Split-Path -Parent (Split-Path -Parent $javaPath)
}

if ($Help) {
    Show-Usage
    exit 0
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$outputDirectory = Join-Path $repoRoot 'x64\Development\plugins\android'

$AndroidSdk = Get-FirstDirectory @(
    $AndroidSdk,
    $env:ANDROID_SDK,
    $env:ANDROID_SDK_ROOT,
    $env:ANDROID_HOME
)
if (-not $AndroidSdk) {
    throw 'Android SDK not found. Pass -AndroidSdk or set ANDROID_SDK/ANDROID_SDK_ROOT/ANDROID_HOME.'
}

$AndroidNdk = Get-FirstDirectory @(
    $AndroidNdk,
    $env:ANDROID_NDK,
    $env:ANDROID_NDK_HOME,
    $env:ANDROID_NDK_ROOT,
    $env:NDK_HOME
)
if (-not $AndroidNdk) {
    $ndkContainer = Join-Path $AndroidSdk 'ndk'
    if (Test-Path -LiteralPath $ndkContainer -PathType Container) {
        $latestNdk = Get-ChildItem -LiteralPath $ndkContainer -Directory |
            Sort-Object Name -Descending |
            Select-Object -First 1
        if ($latestNdk) {
            $AndroidNdk = $latestNdk.FullName
        }
    }
}
if (-not $AndroidNdk) {
    throw 'Android NDK not found. Pass -AndroidNdk or set ANDROID_NDK/ANDROID_NDK_HOME/ANDROID_NDK_ROOT.'
}

$JdkHome = Get-FirstDirectory @($JdkHome, $env:JAVA_HOME)
if (-not $JdkHome) {
    throw 'JDK not found. Pass -JdkHome or set JAVA_HOME to a JDK containing javac.'
}

$Java8Home = Find-Java8Home $Java8Home
if (-not $Java8Home) {
    throw 'Java 8 not found. Pass -Java8Home or put a Java 8 java.exe first in PATH.'
}

$cmake = (Get-Command cmake.exe -ErrorAction Stop).Source
$javac = Require-File (Join-Path $JdkHome 'bin\javac.exe') 'javac'
$jar = Require-File (Join-Path $JdkHome 'bin\jar.exe') 'jar'
$javadoc = Require-File (Join-Path $JdkHome 'bin\javadoc.exe') 'javadoc'
$jdkKeytool = Require-File (Join-Path $JdkHome 'bin\keytool.exe') 'JDK keytool'
$java8 = Require-File (Join-Path $Java8Home 'bin\java.exe') 'Java 8 runtime'
$java8Keytool = Require-File (Join-Path $Java8Home 'bin\keytool.exe') 'Java 8 keytool'
$buildTools = Join-Path $AndroidSdk "build-tools\$BuildToolsVersion"
$aapt = Require-File (Join-Path $buildTools 'aapt.exe') 'aapt'
$apksigner = Require-File (Join-Path $buildTools 'apksigner.bat') 'apksigner'
$androidJar = Require-File (Join-Path $AndroidSdk "platforms\$AndroidPlatform\android.jar") 'Android platform'

$java8Version = Get-JavaVersionText $java8
if ($java8Version -notmatch 'version "1\.8\.') {
    throw "-Java8Home must point to Java 8. Detected: $($java8Version.Trim())"
}

$targets = @()
if ($Abi -eq 'all' -or $Abi -eq 'arm32') {
    $targets += [PSCustomObject]@{
        Name = 'arm32'
        AndroidAbi = 'armeabi-v7a'
        BuildDirectory = Join-Path $repoRoot 'build-android-release-arm32'
        ApkName = 'org.renderdoc.renderdoccmd.arm32.apk'
    }
}
if ($Abi -eq 'all' -or $Abi -eq 'arm64') {
    $targets += [PSCustomObject]@{
        Name = 'arm64'
        AndroidAbi = 'arm64-v8a'
        BuildDirectory = Join-Path $repoRoot 'build-android-release-arm64'
        ApkName = 'org.renderdoc.renderdoccmd.arm64.apk'
    }
}

Write-Host "Repository: $repoRoot"
Write-Host "Android SDK: $AndroidSdk"
Write-Host "Android NDK: $AndroidNdk"
Write-Host "JDK: $JdkHome"
Write-Host "Java 8: $Java8Home"
Write-Host "Targets: $($targets.Name -join ', ')"

$env:ANDROID_SDK = $AndroidSdk
$env:ANDROID_NDK = $AndroidNdk
$env:JAVA_HOME = $JdkHome
$env:GIT_CONFIG_COUNT = '1'
$env:GIT_CONFIG_KEY_0 = 'safe.directory'
$env:GIT_CONFIG_VALUE_0 = $repoRoot.Replace('\', '/')

foreach ($target in $targets) {
    $cmakeArguments = @(
        '-S', $repoRoot,
        '-B', $target.BuildDirectory,
        '-G', 'MinGW Makefiles',
        '-DBUILD_ANDROID=On',
        '-DCMAKE_BUILD_TYPE=Release',
        '-DSTRIP_ANDROID_LIBRARY=On',
        "-DANDROID_ABI=$($target.AndroidAbi)",
        "-DANDROID_PLATFORM=$AndroidPlatform",
        "-DANDROID_BUILD_TOOLS_VERSION=$BuildToolsVersion",
        "-DAPK_TARGET_ID=$AndroidPlatform",
        "-DJava_JAVA_EXECUTABLE=$($java8.Replace('\', '/'))",
        "-DJava_JAVAC_EXECUTABLE=$($javac.Replace('\', '/'))",
        # CMake 3.31 still expects javah for this old branch. It is not invoked by the build.
        "-DJava_JAVAH_EXECUTABLE=$($javac.Replace('\', '/'))",
        "-DJava_JAR_EXECUTABLE=$($jar.Replace('\', '/'))",
        "-DJava_JAVADOC_EXECUTABLE=$($javadoc.Replace('\', '/'))"
    )

    Invoke-Checked $cmake $cmakeArguments "Configure $($target.Name) Release project"
}

if ($ConfigureOnly) {
    Write-Host 'CMake projects generated successfully.'
    exit 0
}

foreach ($target in $targets) {
    $keystore = Join-Path $target.BuildDirectory 'renderdoccmd\debug.keystore'
    if (-not (Test-Path -LiteralPath $keystore -PathType Leaf)) {
        $keystoreArguments = @(
            '-genkeypair', '-storetype', 'JKS',
            '-keystore', $keystore,
            '-storepass', 'android',
            '-alias', 'rdocandroidkey',
            '-keypass', 'android',
            '-keyalg', 'RSA',
            '-keysize', '2048',
            '-validity', '10000',
            '-dname', 'CN=, OU=, O=, L=, ST=, C='
        )
        Invoke-Checked $jdkKeytool $keystoreArguments "Create JKS keystore for $($target.Name)"
    }

    $validateKeystoreArguments = @('-list', '-keystore', $keystore, '-storepass', 'android')
    Invoke-Checked $java8Keytool $validateKeystoreArguments "Validate Java 8-compatible keystore for $($target.Name)"
}

# Android build-tools 26 dx/apksigner require Java 8 at execution time.
$env:JAVA_HOME = $Java8Home

foreach ($target in $targets) {
    $buildArguments = @('--build', $target.BuildDirectory, '--target', 'apk', '--parallel', "$Jobs")
    Invoke-Checked $cmake $buildArguments "Build and strip $($target.Name) APK"

    $apk = Join-Path $target.BuildDirectory "bin\$($target.ApkName)"
    Require-File $apk "$($target.Name) APK" | Out-Null
    Invoke-Checked $aapt @('dump', 'badging', $apk) "Inspect $($target.Name) APK"
    Invoke-Checked $apksigner @('verify', '--verbose', $apk) "Verify $($target.Name) APK signature"

    if (-not $NoCopy) {
        New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
        Copy-Item -LiteralPath $apk -Destination (Join-Path $outputDirectory $target.ApkName) -Force
    }

    $apkFile = Get-Item -LiteralPath $apk
    Write-Host ("Built {0}: {1:N0} bytes" -f $apkFile.FullName, $apkFile.Length)
}

if (-not $NoCopy) {
    Write-Host "Copied APKs to: $outputDirectory"
}
Write-Host 'RenderDoc Android APK build completed successfully.'
