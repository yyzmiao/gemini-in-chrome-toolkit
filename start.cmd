@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"

where pwsh >nul 2>&1
if not errorlevel 1 (
    pwsh -NoProfile -File "%~dp0scripts\gemini_chrome.ps1"
    set "TOOL_EXIT=!errorlevel!"
    echo.
    pause
    exit /b !TOOL_EXIT!
)

where python >nul 2>&1
if not errorlevel 1 (
    python "%~dp0scripts\gemini_chrome.py"
    set "TOOL_EXIT=!errorlevel!"
    echo.
    pause
    exit /b !TOOL_EXIT!
)

echo PowerShell 7.4 or Python 3.10 is required.
echo https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows
echo https://www.python.org/downloads/windows/
echo.
pause
exit /b 1
