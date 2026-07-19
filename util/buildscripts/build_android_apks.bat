@echo off
setlocal

if /I "%~1"=="-h" goto :help
if /I "%~1"=="--help" goto :help
if /I "%~1"=="help" goto :help

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_android_apks.ps1" %*
exit /b %ERRORLEVEL%

:help
echo Build RenderDoc Android APKs for Windows development builds.
echo.
echo Usage:
echo   build_android_apks.bat [all^|arm32^|arm64] [options]
echo.
echo Options:
echo   -ConfigureOnly        Generate CMake projects without building.
echo   -NoCopy               Do not copy APKs to x64\Development\plugins\android.
echo   -Jobs N               Parallel build jobs. Default: processor count.
echo   -AndroidSdk PATH      Android SDK root.
echo   -AndroidNdk PATH      Android NDK root.
echo   -JdkHome PATH         JDK containing java, javac, jar and keytool.
echo   -HostCppCompiler PATH Windows C++ compiler used to build host helper tools.
echo   -MakeProgram PATH     Make executable used by the MinGW Makefiles generator.
echo   -BuildToolsVersion V  Android build-tools version. Default: newest version containing d8.
echo   -AndroidPlatform P    Android platform. Default: android-28.
echo.
echo Examples:
echo   build_android_apks.bat
echo   build_android_apks.bat arm64
echo   build_android_apks.bat all -ConfigureOnly
echo   build_android_apks.bat all -Jobs 8 -NoCopy
exit /b 0
