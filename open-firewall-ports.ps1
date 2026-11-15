# Run as Administrator in PowerShell to allow incoming iPhone UDP Handshakes & LAN Discovery
New-NetFirewallRule -DisplayName "PC-to-iPhone Audio Streamer (UDP)" `
    -Direction Inbound `
    -Protocol UDP `
    -LocalPort 49152,49153 `
    -Action Allow `
    -Profile Private,Domain

Write-Host "Firewall rules for UDP ports 49152 & 49153 configured successfully!" -ForegroundColor Green
