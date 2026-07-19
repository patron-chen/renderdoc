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
    [string]$HostCppCompiler,
    [string]$MakeProgram,
    [string]$BuildToolsVersion,
    [string]$AndroidPlatform = 'android-28',
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
  -JdkHome PATH         JDK containing java, javac, jar and keytool.
  -HostCppCompiler PATH Windows C++ compiler used to build host helper tools.
  -MakeProgram PATH     Make executable used by the MinGW Makefiles generator.
  -BuildToolsVersion V  Android build-tools version. Default: newest version containing d8.
  -AndroidPlatform P    Android platform. Default: android-28.

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

function Get-BuildToolsVersionKey {
    param([string]$VersionText)

    $parsedVersion = [Version]'0.0'
    if ([Version]::TryParse($VersionText, [ref]$parsedVersion)) {
        return $parsedVersion
    }

    return [Version]'0.0'
}

function Resolve-ExecutableCommand {
    param([string]$Candidate)

    if (-not $Candidate) {
        return $null
    }
    if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Candidate).Path
    }

    $command = Get-Command $Candidate -CommandType Application -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    return $null
}

function Find-HostCppCompiler {
    param([string]$ExplicitCompiler)

    foreach ($candidate in @($ExplicitCompiler, $env:CXX, 'c++.exe', 'g++.exe')) {
        $compiler = Resolve-ExecutableCommand $candidate
        if ($compiler) {
            return $compiler
        }
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $installations = @(
            & $vswhere -latest -products '*' -property installationPath
            & $vswhere -all -products '*' -property installationPath
        ) | Where-Object { $_ } | Select-Object -Unique

        foreach ($installation in $installations) {
            foreach ($relativePath in @(
                'VC\Tools\Llvm\x64\bin\clang++.exe',
                'VC\Tools\Llvm\bin\clang++.exe'
            )) {
                $compiler = Resolve-ExecutableCommand (Join-Path $installation $relativePath)
                if ($compiler) {
                    return $compiler
                }
            }
        }
    }

    $compiler = Resolve-ExecutableCommand 'clang++.exe'
    if ($compiler) {
        return $compiler
    }

    throw 'Windows host C++ compiler not found. Pass -HostCppCompiler or install Visual Studio LLVM/MinGW g++.'
}

function Find-MakeProgram {
    param(
        [string]$ExplicitProgram,
        [string]$NdkRoot
    )

    foreach ($candidate in @(
        $ExplicitProgram,
        'mingw32-make.exe',
        (Join-Path $NdkRoot 'prebuilt\windows-x86_64\bin\make.exe'),
        (Join-Path $NdkRoot 'prebuilt\windows\bin\make.exe')
    )) {
        $program = Resolve-ExecutableCommand $candidate
        if ($program) {
            return $program
        }
    }

    throw 'Make executable not found. Pass -MakeProgram or install MinGW Make.'
}

function Find-D8BuildTools {
    param(
        [string]$SdkRoot,
        [string]$ExplicitVersion
    )

    $buildToolsRoot = Join-Path $SdkRoot 'build-tools'
    if (-not (Test-Path -LiteralPath $buildToolsRoot -PathType Container)) {
        throw "Android build-tools directory not found: $buildToolsRoot"
    }

    if ($ExplicitVersion) {
        $candidate = Join-Path $buildToolsRoot $ExplicitVersion
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
            throw "Android build-tools $ExplicitVersion not found: $candidate"
        }
        if (-not (Test-Path -LiteralPath (Join-Path $candidate 'd8.bat') -PathType Leaf)) {
            throw "Android build-tools $ExplicitVersion does not contain d8.bat. Select a modern build-tools version to use a current JDK."
        }
        return (Get-Item -LiteralPath $candidate)
    }

    $candidate = Get-ChildItem -LiteralPath $buildToolsRoot -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'd8.bat') -PathType Leaf } |
        Sort-Object @{ Expression = { Get-BuildToolsVersionKey $_.Name }; Descending = $true }, Name -Descending |
        Select-Object -First 1
    if (-not $candidate) {
        throw 'No Android build-tools version containing d8.bat was found. Install a modern Android SDK build-tools package.'
    }

    return $candidate
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
    throw 'JDK not found. Pass -JdkHome or set JAVA_HOME to a JDK containing java and javac.'
}

$cmake = (Get-Command cmake.exe -ErrorAction Stop).Source
$java = Require-File (Join-Path $JdkHome 'bin\java.exe') 'java'
$javac = Require-File (Join-Path $JdkHome 'bin\javac.exe') 'javac'
$jar = Require-File (Join-Path $JdkHome 'bin\jar.exe') 'jar'
$javadoc = Require-File (Join-Path $JdkHome 'bin\javadoc.exe') 'javadoc'
$jdkKeytool = Require-File (Join-Path $JdkHome 'bin\keytool.exe') 'JDK keytool'
$HostCppCompiler = Find-HostCppCompiler $HostCppCompiler
$MakeProgram = Find-MakeProgram $MakeProgram $AndroidNdk
$buildToolsDirectory = Find-D8BuildTools $AndroidSdk $BuildToolsVersion
$BuildToolsVersion = $buildToolsDirectory.Name
$buildTools = $buildToolsDirectory.FullName
$aapt = Require-File (Join-Path $buildTools 'aapt.exe') 'aapt'
$d8 = Require-File (Join-Path $buildTools 'd8.bat') 'd8'
$apksigner = Require-File (Join-Path $buildTools 'apksigner.bat') 'apksigner'
$androidJar = Require-File (Join-Path $AndroidSdk "platforms\$AndroidPlatform\android.jar") 'Android platform'

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
Write-Host "Host C++ compiler: $HostCppCompiler"
Write-Host "Make: $MakeProgram"
Write-Host "Android build-tools: $BuildToolsVersion"
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
        "-DCMAKE_MAKE_PROGRAM=$($MakeProgram.Replace('\', '/'))",
        '-DBUILD_ANDROID=On',
        '-DCMAKE_BUILD_TYPE=Release',
        '-DSTRIP_ANDROID_LIBRARY=On',
        "-DANDROID_ABI=$($target.AndroidAbi)",
        "-DANDROID_PLATFORM=$AndroidPlatform",
        "-DANDROID_BUILD_TOOLS_VERSION=$BuildToolsVersion",
        "-DAPK_TARGET_ID=$AndroidPlatform",
        "-DHOST_NATIVE_CPP_COMPILER=$($HostCppCompiler.Replace('\', '/'))",
        "-DJava_JAVA_EXECUTABLE=$($java.Replace('\', '/'))",
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
    Invoke-Checked $jdkKeytool $validateKeystoreArguments "Validate keystore for $($target.Name)"
}

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
