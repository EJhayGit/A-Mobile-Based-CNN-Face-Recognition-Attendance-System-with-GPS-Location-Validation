[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 8080,
    [switch]$NoBrowser,
    [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$environmentPath = Join-Path $repoRoot "backend/.env"
$pythonPath = Join-Path $repoRoot "backend/.venv/Scripts/python.exe"
$healthUrl = "http://127.0.0.1:$Port/health"
$launchNonce = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$siteUrl = "http://127.0.0.1:$Port/login?launcher=$launchNonce"
$serverProcess = $null

function Import-DemoEnvironment {
    $allowedNames = @(
        "DATABASE_URL",
        "JWT_SECRET",
        "COOKIE_SECURE",
        "ACCESS_TOKEN_MINUTES",
        "REFRESH_TOKEN_HOURS",
        "ACTIVATION_CODE_HOURS",
        "ACTIVATION_MAX_ATTEMPTS"
    )

    foreach ($rawLine in Get-Content -LiteralPath $environmentPath) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) {
            continue
        }

        $separator = $line.IndexOf("=")
        if ($separator -le 0) {
            continue
        }

        $name = $line.Substring(0, $separator).Trim()
        if ($allowedNames -notcontains $name) {
            continue
        }

        $value = $line.Substring($separator + 1).Trim()
        if (
            $value.Length -ge 2 -and
            (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'")))
        ) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        [Environment]::SetEnvironmentVariable($name, $value, "Process")
    }

    foreach ($requiredName in @("DATABASE_URL", "JWT_SECRET")) {
        if (-not [Environment]::GetEnvironmentVariable($requiredName, "Process")) {
            throw "$requiredName is missing from backend/.env."
        }
    }
}

function Test-DemoHealth {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $healthUrl -TimeoutSec 2
        if ($response.StatusCode -ne 200) {
            return $false
        }
        $body = $response.Content | ConvertFrom-Json
        return $body.status -eq "ok"
    }
    catch {
        return $false
    }
}

if (-not (Test-Path -LiteralPath $environmentPath -PathType Leaf)) {
    throw "Missing backend/.env. Configure it before starting the demo."
}
if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
    throw "Missing backend Python environment. Install backend requirements first."
}

Import-DemoEnvironment

# Windows environment names are case-insensitive, but some development shells
# provide both Path and PATH. Windows PowerShell's Start-Process rejects that
# duplicate, so normalize it only inside this launcher process.
$processEnvironment = [Environment]::GetEnvironmentVariables("Process")
$pathNames = @(
    $processEnvironment.Keys |
        ForEach-Object { [string]$_ } |
        Where-Object { $_.ToUpperInvariant() -eq "PATH" }
)
if ($pathNames.Count -gt 1) {
    $pathValue = [string]$processEnvironment["Path"]
    if (-not $pathValue) {
        $pathValue = [string]$processEnvironment["PATH"]
    }
    [Environment]::SetEnvironmentVariable("PATH", $null, "Process")
    [Environment]::SetEnvironmentVariable("Path", $pathValue, "Process")
}

if (Test-DemoHealth) {
    Write-Host "The thesis demo is already running at $siteUrl"
    if (-not $NoBrowser -and -not $CheckOnly) {
        Start-Process -FilePath $siteUrl
    }
    exit 0
}

Write-Host "Starting the thesis Fleet Manager website and API..."
$arguments = @(
    "-m",
    "backend.server",
    "--host",
    "127.0.0.1",
    "--port",
    $Port.ToString()
)

try {
    $serverProcess = Start-Process `
        -FilePath $pythonPath `
        -ArgumentList $arguments `
        -WorkingDirectory $repoRoot `
        -NoNewWindow `
        -PassThru

    $ready = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        if ($serverProcess.HasExited) {
            throw "The backend exited before its health check passed."
        }
        if (Test-DemoHealth) {
            $ready = $true
            break
        }
        Start-Sleep -Milliseconds 250
    }

    if (-not $ready) {
        throw "The backend did not become healthy within 15 seconds."
    }

    Write-Host "Demo ready: $siteUrl"
    if ($CheckOnly) {
        Write-Host "Launcher health check passed."
        exit 0
    }

    if (-not $NoBrowser) {
        Start-Process -FilePath $siteUrl
    }

    Write-Host "Keep this window open. Press Ctrl+C to stop the demo."
    while (-not $serverProcess.WaitForExit(500)) {
    }
    exit $serverProcess.ExitCode
}
finally {
    if ($serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force
        $serverProcess.WaitForExit()
    }
}
