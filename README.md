# QuickFolder for macOS

**QuickFolder** là ứng dụng tiện ích siêu nhẹ cho macOS (lấy cảm hứng từ [Default Folder X](https://www.stclairsoft.com/DefaultFolderX/)), tập trung vào việc **chọn nhanh thư mục đích khi Lưu (Save) hoặc Mở (Open) file** từ bất kỳ ứng dụng nào (Microsoft Word, Excel, Chrome, Preview, VS Code...).

## ✨ Tính năng nổi bật

- **Thanh bên nổi tự động (Auto-Docking Sidebar)**: Tự động xuất hiện bám sát cạnh phải hoặc cạnh trái của hộp thoại `Save` / `Open` ngay khi ứng dụng bất kỳ mở hộp thoại lưu/mở file (kể cả trên thiết lập đa màn hình).
- **Cửa sổ Finder đang mở theo thời gian thực**: Liệt kê toàn bộ các thư mục đang mở trên Finder để nhảy tới chỉ với **1 cú nhấp chuột** (không cướp tiêu điểm bàn phím của hộp thoại Save).
- **Thư mục gần đây & Đã ghim yêu thích**: Tự động đồng bộ lịch sử thư mục gần đây từ Finder (`FXRecentFolders`), lưu lịch sử các thư mục đã chọn và cho phép ghim (Pin) các thư mục hay dùng lên đầu.
- **Chuyển thư mục siêu tốc & Tự động cuộn cột cuối**:
  - Chọn trực tiếp tức thì (`0ms`) với các thư mục trên thanh bên chuẩn của macOS.
  - Tự động điền đường dẫn Unicode siêu nhanh (`~0.2s`, không ghi đè Clipboard) cho các thư mục con sâu (kể cả Google Drive / CloudStorage) và tự động cuộn thanh trượt ngang `Column View` tới cột cuối cùng.
- **Chế độ Menu Bar gọn nhẹ**: Hỗ trợ ẩn biểu tượng khỏi thanh Dock macOS, chỉ hiển thị gọn trên thanh Menu Bar phía trên.

## ⌨️ Phím tắt toàn cục (Global Hotkeys)

| Phím tắt | Chức năng |
| :--- | :--- |
| `⌘ ⇧ F` | Nhảy ngay hộp thoại Save/Open tới cửa sổ Finder đang mở đầu tiên |
| `⌘ ⇧ D` | Hiện / Ẩn nhanh bảng chọn thư mục nổi |
| `⌥ 1` … `⌥ 9` | Chọn nhanh thư mục ở vị trí số `1` … `9` trong danh sách |

---

## 📥 Tải về & Cài đặt nhanh (macOS 14.0+ Universal: Apple Silicon & Intel)

1. Tải bộ cài mới nhất tại trang **[Releases](https://github.com/hungmtuci/QuickFolder/releases/latest)**:
   - **`QuickFolder-Installer-v1.0.0.dmg`** *(Khuyên dùng)*
   - Hoặc **`QuickFolder-v1.0.0-macOS.zip`**
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
chmod +x build_app.sh
./build_app.sh
```

Sau khi chạy xong `./build_app.sh`:
- Ứng dụng Universal Binary (`arm64` + `x86_64`) được tạo tại `./QuickFolder.app`
- Bộ cài `.dmg` và `.zip` được xuất ra tại thư mục `./dist/`

## 📄 Giấy phép

Phát hành theo giấy phép [MIT License](LICENSE).
