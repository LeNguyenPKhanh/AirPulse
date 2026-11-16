# AirPulse Windows quick setup: open firewall ports and launch sender (if prebuilt exists).
# Run as Administrator for firewall changes.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

Write-Host "== AirPulse Windows setup ==" -ForegroundColor Cyan

$fw = Join-Path $root "open-firewall-ports.ps1"
if (Test-Path $fw) {
    try {
        & $fw
    } catch {
        Write-Warning "Could not configure firewall (run this script as Administrator). $_"
    }
} else {
    Write-Warning "open-firewall-ports.ps1 not found."
}

$exe = Join-Path $root "windows-sender\publish\PcAudioStreamer.exe"
if (Test-Path $exe) {
    Write-Host "Starting sender: $exe" -ForegroundColor Green
    Start-Process -FilePath $exe
} else {
    Write-Host "Prebuilt sender not found at windows-sender\publish\PcAudioStreamer.exe" -ForegroundColor Yellow
    Write-Host "Run from source: dotnet run --project .\windows-sender\PcAudioStreamer.csproj -c Release" -ForegroundColor Yellow
}
