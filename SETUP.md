# AirPulse Setup Guide (A to Z)

Step-by-step setup for streaming audio from a Windows PC to an iPhone with AirPulse.

## 1) What you need

- **Windows PC** (Windows 10/11) and **iPhone** on the **same Wi-Fi/LAN**
- **iPhone iOS 26+**
- An **unsigned `.ipa`** of AirPulse (from this repo, e.g. `AirPulse-iOS-stable-source.ipa`, or from GitHub Actions artifact `PCAudioReceiver-iOS-IPA`)
- A sideload tool on your computer: [Sideloadly](https://sideloadly.io/) or [SideStore](https://sidestore.io/) + your Apple ID

## 2) Prepare the PC (Windows Sender)

1. Download/clone this repo and open its folder.
2. **Open firewall ports once** (required for discovery/streaming):
   - Right-click Start → **Windows Terminal (Admin)** / **PowerShell (Admin)**
   - Run:
     ```powershell
     cd path\to\AirPulse
     .\open-firewall-ports.ps1
     ```
   - This allows inbound UDP **49152** and **49153**.
3. **Start the sender app** (choose one):
   - Prebuilt (if present): run `windows-sender\publish\PcAudioStreamer.exe`
   - From source (needs [.NET 9 SDK](https://dotnet.microsoft.com/download)):
     ```powershell
     dotnet run --project .\windows-sender\PcAudioStreamer.csproj -c Release
     ```
4. In the sender app, select the audio device (WASAPI loopback/output to capture) and click **Start/Stream**. Keep it running.

> Tip: `.\setup-windows.ps1` (run as Admin) can open firewall ports and launch the prebuilt sender if available.

## 3) Install the app on iPhone (sideload)

1. Connect iPhone to your computer (USB) or use the wireless method supported by your sideload tool.
2. Open **Sideloadly** or **SideStore**, sign in with your Apple ID.
3. Select the AirPulse `.ipa` (e.g. `AirPulse-iOS-stable-source.ipa`) and install it to the iPhone.
4. On iPhone, if prompted: go to **Settings → General → VPN & Device Management** and **Trust** the developer profile.
5. Open **AirPulse** and allow requested permissions (Local Network/Bluetooth) for auto-discovery.

> Note: With a free Apple ID, the app signing usually expires in ~7 days and must be reinstalled/refreshed.

## 4) Connect and stream

1. Make sure sender is streaming and PC/iPhone are on the same network.
2. In **AirPulse** on iPhone, wait for your PC to appear (or tap **Rescan**).
3. Tap **Connect** / **Start Audio Stream**.
4. Adjust volume, jitter buffer, and **Mix With Other iPhone Apps** / **Duck Other Audio** as needed.

## 5) If something doesn't work

- **PC not discovered:** same Wi-Fi/LAN? Firewall ports 49152-49153 opened? Sender running and streaming? Try **Rescan**.
- **Can't install IPA:** IPA is unsigned and must be sideloaded; re-sign/refresh if the 7-day certificate expired.
- **Multiple network adapters (Ethernet/Wi-Fi/virtual):** the app picks the most stable endpoint automatically; if names differ per interface, grouping may be imperfect.
- **System Bluetooth pairing prompt:** iOS system prompt (not an in-app status) — allow or deny based on your needs.
- **App requires iOS 26+:** older devices/iOS versions may not run this build.

## 6) Build from source (optional)

- **Windows sender publish (self-contained):**
  ```powershell
  dotnet publish .\windows-sender\PcAudioStreamer.csproj -c Release -r win-x64 --self-contained true -o .\windows-sender\publish
  ```
- **iOS (macOS + Xcode 26+ SDK + XcodeGen):**
  ```bash
  cd ios-receiver
  xcodegen generate
  open PCAudioReceiver.xcodeproj
  ```
  Then build/sign for your device in Xcode.
- **CI:** GitHub Actions workflow `Build iOS Receiver (.ipa) & Windows 11 Sender` produces an unsigned IPA artifact and a Windows sender artifact.
