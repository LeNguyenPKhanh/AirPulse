# PC-to-iPhone Real-Time Audio Streamer

Hệ thống truyền âm thanh thời gian thực độ trễ cực thấp (`5ms – 20ms`) từ **Windows 11 PC** sang **iPhone**, hỗ trợ:
- **BLE + Wi-Fi Auto-Discovery:** Tự động tìm kiếm và kết nối 1-chạm giữa Windows 11 và iPhone (không cần nhập IP thủ công).
- **Chạy ngầm (Background Audio):** Tiếp tục phát âm thanh từ PC ngay cả khi khóa màn hình iPhone hoặc chuyển sang ứng dụng khác.
- **Trộn âm thanh nguyên bản (`.mixWithOthers`):** Nghe âm thanh từ PC **đồng thời** với âm thanh trên iPhone (TikTok, YouTube, Game, Nhạc, Thông báo) mà không làm dừng nhạc/video trên iPhone, kèm tùy chọn **Duck Others (`.duckOthers`)**.

---

## Cấu trúc Dự án

```text
├── windows-sender/                  # Ứng dụng Windows 11 (C# .NET 9 WPF + NAudio WASAPI + Concentus Opus + WinRT BLE)
│   ├── Audio/WasapiAudioStreamer.cs # Thu âm WASAPI Loopback, mã hóa Opus/PCM16, đóng gói UDP 12-byte & Keep-Alive
│   ├── Discovery/BleDiscoveryServer.cs # Phát sóng BLE GATT & LAN Beacon tự động ghép nối
│   ├── Protocol/AudioPacketHeader.cs   # Định nghĩa giao thức gói tin UDP 12-byte ("AS" Header)
│   ├── MainWindow.xaml(.cs)         # Giao diện điều khiển Windows 11
│   └── publish/PcAudioStreamer.exe  # Bản build thực thi sẵn trên Windows 11
├── ios-receiver/                    # Ứng dụng iOS Native (SwiftUI + AVAudioEngine + CoreBluetooth)
│   ├── project.yml                  # Cấu hình XcodeGen tự động sinh Xcode Project
│   └── PCAudioReceiver/
│       ├── Audio/AudioSessionManager.swift    # Cấu hình AVAudioSession (.playback + .mixWithOthers / .duckOthers)
│       ├── Audio/OpusAndPcmDecoder.swift      # Giải mã Opus & Raw PCM16 sang AVAudioPCMBuffer
│       ├── Bluetooth/BleScannerManager.swift  # Quét BLE & Wi-Fi Beacon tự động nhận diện PC
│       ├── Network/UdpAudioEngineReceiver.swift # Nhận UDP, Jitter Buffer & phát AVAudioPlayerNode liên tục
│       └── Views/ContentView.swift            # Giao diện iOS điều khiển âm lượng, độ trễ & trộn âm
├── .github/workflows/ios-build.yml  # GitHub Actions tự động biên dịch file .ipa miễn phí trên macOS runner
└── open-firewall-ports.ps1          # Script mở cổng UDP 49152-49153 trên Windows Firewall
```

---

## Hướng dẫn Sử dụng

### Bước 1: Chạy Ứng dụng phát trên Windows 11
1. Mở PowerShell (Run as Administrator) và chạy script mở cổng UDP Firewall (chỉ cần chạy 1 lần):
   ```powershell
   .\open-firewall-ports.ps1
   ```
2. Chạy trực tiếp file thực thi đã được build sẵn:
   ```powershell
   .\windows-sender\publish\PcAudioStreamer.exe
   ```
   *(Hoặc chạy qua .NET CLI: `dotnet run --project .\windows-sender\PcAudioStreamer.csproj -c Release`)*

### Bước 2: Build & Cài đặt Ứng dụng iOS từ Windows 11
1. Đẩy toàn bộ thư mục dự án này lên một GitHub Repository (Public hoặc Private).
2. Vào tab **Actions** trên GitHub -> chạy workflow **Build iOS Receiver (.ipa) & Windows 11 Sender**.
3. Tải file artifact **`PCAudioReceiver-iOS-IPA`** (bên trong chứa `PCAudioReceiver-unsigned.ipa`).
4. Dùng **Sideloadly** hoặc **SideStore** trên Windows 11 để ký (sign) bằng Apple ID cá nhân miễn phí và cài đặt vào iPhone.

### Bước 3: Kết nối & Trải nghiệm
1. Trên Windows 11: Chọn thiết bị đầu ra âm thanh (WASAPI Loopback) và nhấn **START STREAMING TO IPHONE**.
2. Trên iPhone: Mở ứng dụng **PC Audio Bridge** -> PC của bạn sẽ tự động xuất hiện trong mục **Auto-Discovery (BLE + Wi-Fi)** -> nhấn **Connect**.
3. Bật **Mix With Native iPhone Apps** để vừa nghe âm thanh PC vừa lướt TikTok/YouTube hoặc khóa màn hình iPhone.
