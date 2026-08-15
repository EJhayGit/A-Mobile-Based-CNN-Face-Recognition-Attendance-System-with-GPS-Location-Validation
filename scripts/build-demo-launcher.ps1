[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $PSScriptRoot "start-demo-launcher.cs"
$outputPath = Join-Path $repoRoot "START_DEMO.exe"

if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Missing launcher source: $sourcePath"
}
if ((Split-Path -Parent $outputPath) -ne $repoRoot) {
    throw "Refusing to write the launcher outside the repository root."
}
if (Test-Path -LiteralPath $outputPath) {
    Remove-Item -LiteralPath $outputPath -Force
}

Add-Type `
    -Path $sourcePath `
    -OutputAssembly $outputPath `
    -OutputType ConsoleApplication

Write-Host "Built $outputPath"
