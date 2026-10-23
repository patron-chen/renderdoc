@echo off
setlocal

REM Forward all arguments to PowerShell wrapper script
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0android_hook.ps1" %*
set "ERR=%ERRORLEVEL%"
if %ERR% neq 0 (
    echo.
    echo [Error] Script exited with code %ERR%.
)
exit /b %ERR%
