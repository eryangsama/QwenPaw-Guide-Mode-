@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Restore-QwenPawGuideModeBackup.ps1" -StartAfterRestore
echo.
pause
