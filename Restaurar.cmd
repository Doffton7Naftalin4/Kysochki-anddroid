@echo off
setlocal DisableDelayedExpansion
set "HD_CAMERA_GAME=%~1"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap.ps1" -Action restore
set "HD_EXIT=%errorlevel%"
echo.
pause
exit /b %HD_EXIT%
