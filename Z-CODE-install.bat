@echo off
setlocal EnableExtensions
set "DEST=%~1"
if "%DEST%"=="" set "DEST=C:\Program Files\7-Zip"
if not exist "%DEST%\" ( echo Destination not found: "%DEST%" & pause & exit /b 1 )

net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '\"%DEST%\"' -Verb RunAs"
    exit /b
)

set "TARGET=%DEST%\Z-CODE.ps1"
set "DATA=%LOCALAPPDATA%\Z-CODE"
echo ==== Z-CODE install ====
echo Program file : %TARGET%
echo Data folder  : %DATA%
echo.

if not exist "%DATA%\" mkdir "%DATA%" >nul 2>&1
echo stop>"%DATA%\ZCODE.stop" 2>nul
powershell -NoProfile -Command "Get-CimInstance Win32_Process | ? { $_.CommandLine -like '*Z-CODE.ps1*' } | %% { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1
del "%DATA%\ZCODE.pid" >nul 2>&1
ping -n 3 127.0.0.1 >nul
del "%DATA%\ZCODE.stop" >nul 2>&1

copy /y "%~dp0Z-CODE.ps1" "%TARGET%" >nul
if errorlevel 1 ( echo Copy failed - is "%DEST%" writable? & pause & exit /b 1 )

powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Register
powershell -NoProfile -Command "Start-Process wscript.exe -ArgumentList ('\"' + (Join-Path $env:LOCALAPPDATA 'Z-CODE\launch.vbs') + '\"')"
ping -n 6 127.0.0.1 >nul

echo.
powershell -NoProfile -Command "$p = Get-CimInstance Win32_Process | ? { $_.CommandLine -like '*Z-CODE.ps1*' }; if ($p) { 'RUNNING - PID ' + ($p.ProcessId -join ', ') } else { 'NOT RUNNING' }"
echo.
echo Log: %DATA%\ZCODE_keycapture_log.txt
pause
