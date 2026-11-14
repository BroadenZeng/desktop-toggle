@echo off
rem ============================================================
rem  TabDesktopSwitch - double-click to toggle:
rem    first double-click  = enable  (single Tab switches desktops)
rem    second double-click = disable (Tab returns to normal)
rem  Requires only built-in Windows PowerShell. No install.
rem ============================================================
setlocal
set "SCRIPT=%~dp0TabDesktopSwitch.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] TabDesktopSwitch.ps1 is missing.
    echo Please keep this BAT and TabDesktopSwitch.ps1 in the same folder.
    pause
    exit /b 1
)
start "" /b "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%SCRIPT%" -Toggle
exit /b 0
