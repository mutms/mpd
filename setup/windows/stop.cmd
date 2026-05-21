@echo off
:: stop.cmd -- suspend all running mpd VMs (state is preserved, resumes instantly).
:: Triggers a UAC prompt if not already running as Administrator.

net session >nul 2>&1
if %errorLevel% == 0 goto :elevated

powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:elevated
powershell -ExecutionPolicy Bypass -File "%~dp0lib\stop.ps1" %*
pause
