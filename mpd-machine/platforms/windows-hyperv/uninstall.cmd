@echo off
:: uninstall.cmd -- delete all mpd VMs and remove the mpd switch and networking.
:: Triggers a UAC prompt if not already running as Administrator.

net session >nul 2>&1
if %errorLevel% == 0 goto :elevated

powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:elevated
powershell -ExecutionPolicy Bypass -File "%~dp0lib\uninstall.ps1" %*
pause
