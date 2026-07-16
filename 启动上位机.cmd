@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0host\start.ps1"
if errorlevel 1 (
    echo.
    echo Failed to start the host application. Check the error above.
    pause
)
