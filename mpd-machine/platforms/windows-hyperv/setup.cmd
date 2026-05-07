@echo off
:: setup.cmd -- double-click to create an mpd-machine VM and configure Windows networking.
:: Triggers a UAC prompt if not already running as administrator.

net session >nul 2>&1
if %errorLevel% == 0 goto :elevated

powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:elevated
powershell -ExecutionPolicy Bypass -File "%~dp0create-headless-vm.ps1" %*
pause
