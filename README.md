# AirPulse (PC-to-iPhone Audio Streamer)

Truyền âm thanh thời gian thực độ trễ thấp từ **Windows 11** sang **iPhone** qua Wi-Fi/LAN (UDP), có tự động tìm PC (Wi-Fi beacon + BLE), chạy nền/khóa màn hình và tùy chọn trộn với âm thanh app khác trên iPhone.

- **iOS Receiver:** SwiftUI native (Liquid Glass/system effects), target iOS 26+.
- **Windows Sender:** .NET 9 WPF + WASAPI loopback, phát hiện tự động qua UDP beacon/BLE.

## Tính năng chính

- Tự động tìm PC trong mạng nội bộ (UDP beacon/GATT), chọn endpoint ổn định khi PC có nhiều card mạng.
- Stream âm thanh PC → iPhone, điều chỉnh buffer/jitter và âm lượng.
- Hỗ trợ audio nền, Lock Screen / Control Center / Dynamic Island (tùy cấu hình session).
- Tùy chọn **Mix With Other iPhone Apps** và **Duck Other Audio**.

## Cấu trúc repo

```text
.
├─ windows-sender/                 # App phát âm thanh trên Windows 11 (C# .NET 9 WPF)
│  ├─ Audio/                       # WASAPI loopback, đóng gói/gửi UDP
│  ├─ Discovery/                   # BLE/UDP beacon discovery
│  ├─ Protocol/                    # Định dạng gói tin
│  ├─ PcAudioStreamer.csproj
│  └─ publish/PcAudioStreamer.exe  # (nếu có) bản build sẵn
├─ ios-receiver/                   # App nhận âm thanh trên iOS (SwiftUI native)
│  ├─ project.yml                  # Cấu hình XcodeGen
│  └─ PCAudioReceiver/
│     ├─ Audio/                    # AVAudioSession, decode/playback
│     ├─ Bluetooth/                # Quét BLE/beacon, chọn endpoint
│     ├─ Network/                   # Nhận UDP, probe/handshake, buffer
│     └─ Views/                    # Giao diện SwiftUI
├─ .github/workflows/ios-build.yml # CI build IPA (unsigned) + Windows sender
├─ open-firewall-ports.ps1         # Mở UDP 49152-49153 trên Windows
└─ README.md
```

## Yêu cầu

- **PC:** Windows 10/11 (khuyến nghị Windows 11), quyền Administrator để mở firewall (lần đầu).
- **iPhone:** iOS 26 trở lên (app dùng API `.glassEffect`/native glass). Cùng mạng Wi-Fi/LAN với PC để auto-discovery/stream ổn định.
- **Cài iOS không cần Mac:** Apple ID + [Sideloadly](https://sideloadly.io/) hoặc [SideStore](https://sidestore.io/) (IPA trong repo/CI là **unsigned**).
- **Tự build (tuỳ chọn):**
  - Windows sender: [.NET 9 SDK](https://dotnet.microsoft.com/download).
  - iOS trên macOS: Xcode (SDK iOS 26+), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Setup từ A-Z

### A. Lấy mã nguồn

```powershell
git clone https://github.com/LeNguyenPKhanh/AirPulse.git
cd AirPulse
```

### B. Cấu hình & chạy Windows Sender (PC)

1. **Mở cổng UDP (chỉ cần 1 lần, chạy PowerShell as Administrator):**
   ```powershell
   .\open-firewall-ports.ps1
   ```
   Mở inbound UDP **49152, 49153** (profile Private/Domain).

2. **Chạy sender:**
   - Dùng bản build sẵn (nếu có trong repo):
     ```powershell
     .\windows-sender\publish\PcAudioStreamer.exe
     ```
   - Hoặc chạy/build từ source:
     ```powershell
     dotnet run --project .\windows-sender\PcAudioStreamer.csproj -c Release
     ```
   - Hoặc publish self-contained (giống CI):
     ```powershell
     dotnet publish .\windows-sender\PcAudioStreamer.csproj -c Release -r win-x64 --self-contained true -o .\windows-sender\publish
     .\windows-sender\publish\PcAudioStreamer.exe
     ```

3. Trên app Windows: chọn thiết bị âm thanh (WASAPI loopback) và nhấn **Start/Stream**. Đảm bảo PC và iPhone cùng mạng.

### C. Cài iOS Receiver lên iPhone

#### Cách 1 (khuyến nghị, không cần Mac): dùng GitHub Actions + sideload

1. Fork/đẩy repo lên GitHub của bạn (hoặc dùng repo này).
2. Vào tab **Actions** → workflow **Build iOS Receiver (.ipa) & Windows 11 Sender** → chạy (`workflow_dispatch`) hoặc push lên `main/master`.
3. Mở run đã hoàn tất → tải artifact **`PCAudioReceiver-iOS-IPA`** (chứa `PCAudioReceiver-unsigned.ipa`).
4. Dùng **Sideloadly** hoặc **SideStore** trên Windows/macOS để ký bằng Apple ID và cài vào iPhone.
   - Apple ID miễn phí: chứng chỉ thường hết hạn sau 7 ngày, cần cài lại/refresh.
   - Lần đầu cần tin cậy developer profile trên iPhone (Settings → General → VPN & Device Management).

#### Cách 2: build trên macOS (có Xcode)

```bash
cd ios-receiver
xcodegen generate
open PCAudioReceiver.xcodeproj
```
Chọn team/signing trong Xcode (hoặc build unsigned theo CI) rồi chạy lên iPhone (iOS 26+).

### D. Kết nối và sử dụng

1. Chạy sender trên Windows và bắt đầu stream.
2. Mở **AirPulse** trên iPhone: app sẽ tự tìm PC (BLE/Wi-Fi). Nhấn **Rescan** nếu cần.
3. Chọn PC (nếu hiện) hoặc để app tự chọn endpoint phù hợp, sau đó nhấn **Start Audio Stream**.
4. Tuỳ chỉnh: âm lượng, jitter buffer, **Mix With Other iPhone Apps** / **Duck Other Audio**.

## Ghi chú & xử lý sự cố

- **Không thấy PC:** kiểm tra cùng mạng/Wi-Fi, firewall đã mở UDP 49152-49153, và sender đang chạy/stream.
- **PC nhiều card mạng (Ethernet/Wi-Fi/vEthernet):** app gộp theo PC và ưu tiên endpoint ổn định (`UDP Probe > Wi-Fi Beacon > BLE...`). Nếu PC phát tên khác nhau theo nguồn, có thể cần định danh cố định từ phía sender.
- **Nhắc/popup ghép nối Bluetooth (pairing) của iOS:** là hành vi hệ thống khi truy cập Bluetooth, không phải trạng thái trong UI của app; có thể chấp nhận/từ chối tuỳ nhu cầu discovery.
- **IPA unsigned:** phải ký/sideload trước khi cài; không cài trực tiếp như app App Store.
- **Yêu cầu iOS 26+:** do dùng hiệu ứng kính hệ thống; máy iOS thấp hơn có thể không tương thích build này.

## Ports

| Port  | Giao thức | Mục đích                          |
|-------|-----------|-----------------------------------|
| 49152 | UDP       | Audio stream / probe / handshake  |
| 49153 | UDP       | LAN discovery beacon              |
