@echo off
setlocal
title Thesis Fleet Manager Demo
cd /d "%~dp0"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-demo.ps1" %*
set "launcher_exit=%errorlevel%"
if not "%launcher_exit%"=="0" (
  echo.
  echo The demo launcher stopped with an error.
  pause
)
exit /b %launcher_exit%
