@echo off
:: setup.cmd -- create a new mpd VM or switch the active VM.
:: Triggers a UAC prompt if not already running as Administrator.

net session >nul 2>&1
if %errorLevel% == 0 goto :elevated

echo.
echo  mpd-machine setup
echo  =================
echo.
echo  This script will:
echo    1. Check Hyper-V and WSL2 ^(Debian^) are available
echo    2. Install Linux tools in WSL: openssl, genisoimage, qemu-utils
echo    3. Install Windows Terminal via winget ^(if not already present^)
echo    4. Generate a local CA certificate for browser-trusted HTTPS
echo    5. Create or reuse the 'mpd' Hyper-V internal network switch
echo    6. Create a new mpd-machine VM -- or switch/re-verify an existing one
echo    7. Configure Windows networking: route, DNS, CA trust store
echo.
echo  Administrator access is required.
echo  A UAC prompt will appear when you press Enter.
echo.
pause

powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:elevated
powershell -ExecutionPolicy Bypass -File "%~dp0lib\setup.ps1" %*
pause
