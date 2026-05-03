@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-QwenPawGuideMode.ps1" -StartAfterInstall
echo.
pause

