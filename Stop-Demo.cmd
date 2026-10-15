@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
set "DEMO_NO_PAUSE="
if /i "%~1"=="--no-pause" set "DEMO_NO_PAUSE=1"
powershell.exe -NoLogo -NoProfile -NonInteractive -Command "$p=New-Object System.Diagnostics.Process; $p.StartInfo.FileName='docker.exe'; $p.StartInfo.Arguments='info --format {{.OSType}}'; $p.StartInfo.UseShellExecute=$false; $p.StartInfo.CreateNoWindow=$true; $p.StartInfo.RedirectStandardOutput=$true; $p.StartInfo.RedirectStandardError=$true; try { [void]$p.Start(); if (-not $p.WaitForExit(15000)) { $p.Kill(); exit 1 }; if ($p.ExitCode -ne 0 -or $p.StandardOutput.ReadToEnd().Trim() -ne 'linux') { exit 1 }; exit 0 } catch { exit 1 }"
if errorlevel 1 (
    echo Docker engine is unavailable; cannot confirm the containers stopped.
    if not defined DEMO_NO_PAUSE pause
    exit /b 1
)
echo Stopping only the AGILA demo containers. Data and configuration are preserved.
powershell.exe -NoLogo -NoProfile -NonInteractive -Command "$ids=@(& docker ps --quiet --filter 'label=com.docker.compose.project=agila-dean-demo' --filter 'label=io.agila.demo=true'); if ($LASTEXITCODE -ne 0) { exit 1 }; foreach ($id in $ids) { & docker stop $id; if ($LASTEXITCODE -ne 0) { exit 1 } }; exit 0"
if errorlevel 1 goto failed
echo Demo stopped. Run Start-Demo.cmd to resume it.
if not defined DEMO_NO_PAUSE pause
exit /b 0
:failed
echo A demo container did not stop. Check Docker Desktop.
if not defined DEMO_NO_PAUSE pause
exit /b 1
