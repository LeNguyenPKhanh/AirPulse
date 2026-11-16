# AirPulse (PC-to-iPhone Audio Streamer)

Stream audio in real time with low latency from **Windows 11** to an **iPhone** over Wi-Fi/LAN (UDP). Includes automatic PC discovery (Wi-Fi beacon + BLE), background/lock-screen playback, and optional audio mixing with other iPhone apps.

- **iOS Receiver:** Native SwiftUI (system Liquid Glass effects), targets iOS 26+.
- **Windows Sender:** .NET 9 WPF + WASAPI loopback, advertises via UDP beacon/BLE.

## Key Features

- Automatic PC discovery on the local network (UDP beacon/GATT) and stable endpoint selection when a PC has multiple network interfaces.
- PC → iPhone audio streaming with adjustable jitter/buffer and volume.
- Background audio with Lock Screen / Control Center / Dynamic Island support (depending on session settings).
- **Mix With Other iPhone Apps** and **Duck Other Audio** options.

## Repository Structure

```text
.
├─ windows-sender/                 # Windows 11 sender app (C# .NET 9 WPF)
│  ├─ Audio/                       # WASAPI loopback capture and UDP send/packetization
│  ├─ Discovery/                   # BLE/UDP beacon discovery
│  ├─ Protocol/                    # Packet format definitions
│  ├─ PcAudioStreamer.csproj
│  └─ publish/PcAudioStreamer.exe  # (if present) prebuilt executable
├─ ios-receiver/                   # iOS receiver app (native SwiftUI)
│  ├─ project.yml                  # XcodeGen configuration
│  └─ PCAudioReceiver/
│     ├─ Audio/                    # AVAudioSession, decode/playback
│     ├─ Bluetooth/                # BLE/beacon scanning, endpoint selection
│     ├─ Network/                   # UDP receive, probe/handshake, buffering
│     └─ Views/                    # SwiftUI interface
├─ .github/workflows/ios-build.yml # CI: build unsigned IPA + Windows sender
├─ open-firewall-ports.ps1         # Opens UDP 49152-49153 on Windows
└─ README.md
```

## Requirements

- **PC:** Windows 10/11 (Windows 11 recommended). Administrator rights are needed once to open firewall ports.
- **iPhone:** iOS 26 or later (the app uses system `.glassEffect` APIs). PC and iPhone should be on the same Wi-Fi/LAN for reliable discovery and streaming.
- **Install on iOS without a Mac:** Apple ID + [Sideloadly](https://sideloadly.io/) or [SideStore](https://sidestore.io/) (IPAs in this repo/CI are **unsigned**).
- **Optional, to build from source:**
  - Windows sender: [.NET 9 SDK](https://dotnet.microsoft.com/download)
  - iOS on macOS: Xcode (iOS 26+ SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Setup from A to Z

### A. Get the source

```powershell
git clone https://github.com/LeNguyenPKhanh/AirPulse.git
cd AirPulse
```

### B. Configure and run the Windows Sender (PC)

1. **Open UDP ports (one-time, run PowerShell as Administrator):**
   ```powershell
   .\open-firewall-ports.ps1
   ```
   This allows inbound UDP **49152** and **49153** (Private/Domain profiles).

2. **Run the sender:**
   - Use the prebuilt executable (if present in the repo):
     ```powershell
     .\windows-sender\publish\PcAudioStreamer.exe
     ```
   - Or run from source:
     ```powershell
     dotnet run --project .\windows-sender\PcAudioStreamer.csproj -c Release
     ```
   - Or publish a self-contained build (same approach as CI):
     ```powershell
     dotnet publish .\windows-sender\PcAudioStreamer.csproj -c Release -r win-x64 --self-contained true -o .\windows-sender\publish
     .\windows-sender\publish\PcAudioStreamer.exe
     ```

3. In the Windows app, select the audio output device (WASAPI loopback) and press **Start/Stream**. Make sure the PC and iPhone are on the same network.

### C. Install the iOS Receiver on iPhone

#### Option 1 (recommended, no Mac required): GitHub Actions + sideload

1. Fork/push this repo to your GitHub account (or use this repo directly).
2. Open the **Actions** tab → run the **Build iOS Receiver (.ipa) & Windows 11 Sender** workflow (`workflow_dispatch`) or push to `main`/`master`.
3. Open the completed run and download the **`PCAudioReceiver-iOS-IPA`** artifact (contains `PCAudioReceiver-unsigned.ipa`). You can also use an unsigned `.ipa` committed in this repo if available.
4. Use **Sideloadly** or **SideStore** (Windows/macOS) to sign with your Apple ID and install it on your iPhone.
   - With a free Apple ID, the signing certificate typically expires after 7 days and must be reinstalled/refreshed.
   - On first install, trust the developer profile on iPhone (Settings → General → VPN & Device Management).

#### Option 2: Build on macOS (with Xcode)

```bash
cd ios-receiver
xcodegen generate
open PCAudioReceiver.xcodeproj
```
Select your team/signing in Xcode (or build unsigned like CI) and run on an iPhone (iOS 26+).

### D. Connect and use

1. Start streaming from the Windows sender.
2. Open **AirPulse** on iPhone: the app will discover PCs automatically (BLE/Wi-Fi). Tap **Rescan** if needed.
3. Select a PC (if shown) or let the app pick the best endpoint, then tap **Start Audio Stream**.
4. Adjust volume, jitter buffer, and toggles for **Mix With Other iPhone Apps** / **Duck Other Audio**.

## Notes & Troubleshooting

- **PC not found:** ensure both devices are on the same network, UDP 49152-49153 is allowed by firewall, and the sender is running/streaming.
- **PC with multiple NICs (Ethernet/Wi-Fi/vEthernet):** the app groups endpoints per PC and prefers the most stable one (`UDP Probe > Wi-Fi Beacon > BLE...`). If the PC advertises different names per interface, a fixed sender-side identifier may be needed for perfect grouping.
- **iOS system Bluetooth pairing prompt:** this is an OS-level prompt when Bluetooth is accessed, not an in-app status; accept/deny based on your discovery needs.
- **Unsigned IPA:** must be signed/sideloaded before installation; it cannot be installed directly like an App Store app.
- **iOS 26+ required:** the UI uses system glass effects; older iOS versions may be incompatible with this build.

## Ports

| Port  | Protocol | Purpose                          |
|-------|----------|----------------------------------|
| 49152 | UDP      | Audio stream / probe / handshake |
| 49153 | UDP      | LAN discovery beacon             |
