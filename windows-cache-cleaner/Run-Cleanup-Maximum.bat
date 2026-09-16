@echo off
setlocal
echo.
echo Maximum includes browser/model caches and supported developer caches.
echo It also requests Windows Update download cleanup and DISM cleanup.
echo Close browsers and developer tools; finish Windows updates first.
echo Diagnostic files, Recycle Bin, hibernation and rollback files are kept.
echo Start by ordinary double-click. Do not use Run as administrator.
echo.
choice /C YN /N /M "Continue with Maximum cleanup? [Y/N] "
if errorlevel 2 exit /b 0

set "SCRIPT_DIR=%~dp0"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Invoke-CleanupElevated.ps1" -Mode Maximum -NoPause
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
