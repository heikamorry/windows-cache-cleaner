@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Invoke-CleanupElevated.ps1" -Mode Analyze -NoPause
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
