@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
set "DEMO_NO_OPEN="
set "DEMO_NO_PAUSE="
set "DEMO_REQUESTED_BIND_ADDRESS="
set "DEMO_REQUESTED_PORT="

:arguments
if "%~1"=="" goto preflight
if /i "%~1"=="--no-open" (
    set "DEMO_NO_OPEN=1"
    shift
    goto arguments
)
if /i "%~1"=="--no-pause" (
    set "DEMO_NO_PAUSE=1"
    shift
    goto arguments
)
if /i "%~1"=="--host" (
    if "%~2"=="" goto usage
    set "DEMO_REQUESTED_BIND_ADDRESS=%~2"
    shift
    shift
    goto arguments
)
if /i "%~1"=="--port" (
    if "%~2"=="" goto usage
    set "DEMO_REQUESTED_PORT=%~2"
    shift
    shift
    goto arguments
)
goto usage

:preflight
echo AGILA - local demonstration
echo This uses a separate demo database and preserves it on restart.
where docker >nul 2>&1
if errorlevel 1 (
    echo Docker is missing. Install Docker Desktop, reboot if requested,
    echo and start its Linux engine. See demo\README.md.
    goto failed
)
call :check_engine
if errorlevel 1 (
    echo Starting Docker Desktop. First startup can take a few minutes...
    docker desktop start --timeout 30
    if errorlevel 1 goto engine_failed
)
call :check_engine
if errorlevel 1 goto engine_failed
docker compose version >nul 2>&1
if errorlevel 1 (
    echo Docker Compose is missing. Update Docker Desktop.
    goto failed
)
docker compose up --help | findstr /c:"--wait" >nul
if errorlevel 1 (
    echo Docker Compose is too old. Update Docker Desktop.
    goto failed
)
if not exist "demo\local" mkdir "demo\local"
echo Checking private demo configuration...
docker run --rm --platform linux/amd64 --mount "type=bind,source=%CD%\demo,target=/demo" --env DEMO_REQUESTED_BIND_ADDRESS --env DEMO_REQUESTED_PORT --entrypoint python ghcr.io/ejhaygit/a-mobile-based-cnn-face-recognition-attendance-system-with-gps-location-validation:1.0.1@sha256:58f7d929648c80cbc515d85817a769940a0e675fa068e73b78032cfd9486f180 /demo/configure.py --directory /demo/local
if errorlevel 1 goto failed
echo Starting database, checking schema, and starting Fleet Manager...
docker compose --project-name agila-dean-demo --env-file demo/local/.env --file demo/compose.yaml up --detach --wait --wait-timeout 180
if errorlevel 1 (
    echo Setup did not finish. No existing database was reset.
    docker compose --project-name agila-dean-demo --env-file demo/local/.env --file demo/compose.yaml logs --no-color --tail 20 setup
    echo Check Docker Desktop and whether the selected port is already used.
    echo See demo\README.md for recovery steps. Keep demo\local private.
    goto failed
)
set "DEMO_BROWSER_HOST="
set "DEMO_BROWSER_PORT="
for /f "usebackq tokens=1,* delims==" %%A in ("demo\local\.env") do (
    if "%%A"=="DEMO_BIND_ADDRESS" set "DEMO_BROWSER_HOST=%%B"
    if "%%A"=="DEMO_HTTP_PORT" set "DEMO_BROWSER_PORT=%%B"
)
echo.
echo Ready: http://%DEMO_BROWSER_HOST%:%DEMO_BROWSER_PORT%/login
echo Your private initial manager login is in demo\local\manager-login.txt
echo Stop-Demo.cmd stops the demo without deleting its data.
if defined DEMO_NO_OPEN goto success
start "" notepad.exe "%CD%\demo\local\manager-login.txt"
start "" "http://%DEMO_BROWSER_HOST%:%DEMO_BROWSER_PORT%/login"
:success
if not defined DEMO_NO_PAUSE pause
exit /b 0

:engine_failed
echo Docker's Linux engine is not ready. Open Docker Desktop, wait until
echo it reports running, then start this launcher again. See demo\README.md.
goto failed

:usage
echo Usage: Start-Demo.cmd [--host PRIVATE_LAN_IP] [--port 8080] [--no-open] [--no-pause]
echo The default is local PC access only. See demo\README.md for phone access.
:failed
if not defined DEMO_NO_PAUSE pause
exit /b 1

:check_engine
powershell.exe -NoLogo -NoProfile -NonInteractive -Command "$p=New-Object System.Diagnostics.Process; $p.StartInfo.FileName='docker.exe'; $p.StartInfo.Arguments='info --format {{.OSType}}'; $p.StartInfo.UseShellExecute=$false; $p.StartInfo.CreateNoWindow=$true; $p.StartInfo.RedirectStandardOutput=$true; $p.StartInfo.RedirectStandardError=$true; try { [void]$p.Start(); if (-not $p.WaitForExit(15000)) { $p.Kill(); exit 1 }; if ($p.ExitCode -ne 0 -or $p.StandardOutput.ReadToEnd().Trim() -ne 'linux') { exit 1 }; exit 0 } catch { exit 1 }"
exit /b %ERRORLEVEL%
