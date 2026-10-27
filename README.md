# QuickFolder for macOS

**QuickFolder** là ứng dụng tiện ích siêu nhẹ cho macOS (lấy cảm hứng từ [Default Folder X](https://www.stclairsoft.com/DefaultFolderX/)), tập trung vào việc **chọn nhanh thư mục đích khi Lưu (Save) hoặc Mở (Open) file** từ bất kỳ ứng dụng nào (Microsoft Word, Excel, Chrome, Preview, VS Code...).

<p align="center">
  <img src="docs/images/hero-save-panel.png" alt="QuickFolder tự động bám sát hộp thoại Save/Open trên macOS" width="960" />
</p>

## 📸 Giao diện Cài đặt & Quản lý Thư mục

<p align="center">
  <img src="docs/images/settings-dashboard.png" alt="Bảng điều khiển Cài đặt & Thử nghiệm QuickFolder" width="760" />
</p>

## ✨ Tính năng nổi bật (v1.2.0)

- **Thanh bên nổi tự động & Bám theo thời gian thực (`AXObserver` 60fps, ~0% CPU khi nghỉ)**: Tự động xuất hiện bám sát cạnh phải hoặc cạnh trái của hộp thoại `Save` / `Open` qua sự kiện `AXObserver` mà không tốn CPU chạy ngầm khi nghỉ.
- **Finder-Click (Click trực tiếp cửa sổ Finder nằm phía sau)**: Khi hộp thoại Save/Open đang mở, chỉ cần di chuột ra vùng cửa sổ Finder bất kỳ trên màn hình và click 1 lần để nhảy hộp thoại Save tới thẳng thư mục đó.
- **Duyệt cây thư mục con nhiều cấp (`▸`) & Tạo thư mục mới tức thì**: Nút `▸` trên mỗi dòng cho phép duyệt đệ quy toàn bộ cây thư mục con hoặc tạo nhanh thư mục con mới và chuyển hộp thoại Save vào ngay lập tức.
- **Thư mục mặc định riêng cho từng ứng dụng (Per-App Default Folder)**: Gán thư mục quen dùng riêng cho từng app (ví dụ Word, Excel, Chrome) và tuỳ chọn tự động nhảy ngay khi mở hộp thoại Save.
- **Phím tắt thông minh không xung đột IDE**: Tự động chỉ bắt `⌘⇧F` khi hộp thoại Save/Open thực sự đang mở (không bao giờ đè lên *Find in Files* `⌘⇧F` trong VS Code / Xcode / trình duyệt), kèm tuỳ chọn đổi tổ hợp phím tắt.
- **Kiểm tra & Tải cập nhật tự động ngay trên Menu Bar (`hungmtuci/QuickFolder`)**: Bấm **“Kiểm tra cập nhật”** trực tiếp từ thanh Menu Bar để đối chiếu tag mới nhất trên GitHub Releases, tự động tải gói cập nhật kèm thanh tiến trình, thay thế `QuickFolder.app`, gỡ cờ cách ly Gatekeeper và khởi động lại phiên bản mới chỉ với 1 cú nhấp chuột.
- **Khởi động êm cùng macOS (`Launch at Login`) & Ẩn trên thanh Dock**: Chạy gọn gàng hoàn toàn trên thanh Menu Bar.

## ⌨️ Phím tắt thông minh (Smart Hotkeys)

| Phím tắt (Tuỳ chỉnh được) | Chức năng |
| :--- | :--- |
| `⌘ ⇧ F` *(hoặc `⌥ F`, `⌃ ⌥ F`)* | Nhảy ngay hộp thoại Save/Open tới cửa sổ Finder đang mở đầu tiên *(chỉ kích hoạt khi đang mở Save/Open)* |
| `⌘ ⇧ D` *(hoặc `⌃ ⌥ D`, `⌥ Space`)* | Hiện / Ẩn nhanh bảng chọn thư mục nổi |
| `⌥ 1` … `⌥ 9` | Chọn nhanh thư mục ở vị trí số `1` … `9` trong danh sách |
| Nút `▸` | Bung menu cây thư mục con nhiều cấp, tạo thư mục con mới hoặc đặt mặc định cho ứng dụng |

---

## 📥 Tải về & Cài đặt nhanh (macOS 14.0+ Universal: Apple Silicon & Intel)

1. Tải bộ cài mới nhất tại trang **[Releases](https://github.com/hungmtuci/QuickFolder/releases/latest)**:
   - **`QuickFolder-Installer-v1.2.0.dmg`** *(Khuyên dùng)*
   - Hoặc **`QuickFolder-v1.2.0-macOS.zip`**
2. Mở file `.dmg`:
   - Kéo `QuickFolder.app` thả vào thư mục **`Applications`**, **HOẶC** nhấp chuột phải vào `Cai_Dat_QuickFolder.command` -> chọn **Open** để tự động cài đặt và gỡ cờ cách ly Gatekeeper.
3. Nếu macOS báo ứng dụng chưa công chứng Apple Developer ID khi mở lần đầu trên máy mới, chạy lệnh sau trong Terminal:
   ```bash
   xattr -cr /Applications/QuickFolder.app && open /Applications/QuickFolder.app
   ```
4. Cấp quyền **Accessibility (Trợ năng)** cho `QuickFolder` trong **System Settings → Privacy & Security → Accessibility** để ứng dụng có thể phát hiện hộp thoại Save/Open và tự động chuyển thư mục.

---

## 🛠️ Tự biên dịch từ mã nguồn (Build from Source)

Yêu cầu: macOS 14.0+ và Xcode hoặc Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/hungmtuci/QuickFolder.git
cd QuickFolder
chmod +x build_app.sh scripts/setup_signing_cert.sh

# (Tuỳ chọn) Tạo chứng chỉ ký nội bộ để macOS giữ quyền Accessibility qua các lần build lại:
./scripts/setup_signing_cert.sh

# Biên dịch Universal Binary và tạo bộ cài .dmg / .zip:
./build_app.sh
```

Sau khi chạy xong `./build_app.sh`:
- Ứng dụng Universal Binary (`arm64` + `x86_64`) được tạo tại `./QuickFolder.app`
- Bộ cài `.dmg` và `.zip` được xuất ra tại thư mục `./dist/`

## 📄 Giấy phép

Phát hành theo giấy phép [MIT License](LICENSE).
