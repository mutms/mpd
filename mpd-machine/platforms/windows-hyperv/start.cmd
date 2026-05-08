@echo off
:: start.cmd -- start the current mpd VM (detected from the persistent route).
:: Triggers a UAC prompt if not already running as Administrator.

net session >nul 2>&1
if %errorLevel% == 0 goto :elevated

powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:elevated
powershell -ExecutionPolicy Bypass -File "%~dp0lib\start.ps1" %*
pause
