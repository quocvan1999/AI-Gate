# 📖 HƯỚNG DẪN PHÁT TRIỂN VÀ ĐÓNG GÓI ỨNG DỤNG AI GATE (macOS)

Tài liệu này hướng dẫn chi tiết cách chạy trong quá trình phát triển (Development / Hot-Reload) và cách xuất bản (Build Release / Packaging) file cài đặt để gửi cho các máy Mac khác.

---

## 📍 THƯ MỤC LÀM VIỆC (QUAN TRỌNG)

Mọi câu lệnh Terminal bên dưới **BẮT BUỘC** phải được thực thi tại **thư mục gốc của dự án**:

```zsh
cd /Users/lyquocvan/Downloads/AI-Stack-Native-v7
```

_(Hoặc mở Terminal, gõ `cd ` rồi kéo thả thư mục `AI-Stack-Native-v7` vào cửa sổ Terminal và nhấn Enter)._

---

## 🛠️ 1. QUÁ TRÌNH PHÁT TRIỂN (DEVELOPMENT & HOT-RELOAD)

Trong quá trình code giao diện hoặc tính năng trong file `AIStackApp.swift`, hãy sử dụng chế độ **Hot-Reload / Auto-Watch**.

### Bước thực hiện:

1. Mở Terminal và chuyển vào thư mục dự án:
   ```zsh
   cd /Users/lyquocvan/Downloads/AI-Stack-Native-v7
   ```
2. Chạy lệnh:
   ```zsh
   ./dev.sh
   ```

### Cơ chế hoạt động:

- Lệnh sẽ tự động build và mở ứng dụng **AI Gate**.
- Cửa sổ Terminal sẽ tiếp tục chạy ngầm để theo dõi file `AIStackApp.swift`.
- Mỗi khi bạn chỉnh sửa code và nhấn **`Cmd + S` (Lưu file)**, script sẽ **tự động tắt app cũ, biên dịch lại code mới và mở lại app ngay lập tức**.
- Nhấn tổ hợp phím **`Ctrl + C`** trong Terminal để dừng chế độ này.

---

## 🚀 2. ĐÓNG GÓI KHI HOÀN THÀNH (BUILD RELEASE CHO MÁY KHÁC)

Khi đã phát triển xong và muốn tạo bộ cài đặt để gửi cho người khác hoặc cài lên các máy Mac khác:

### Bước thực hiện:

1. Mở Terminal và chuyển vào thư mục dự án:
   ```zsh
   cd /Users/lyquocvan/Downloads/AI-Stack-Native-v7
   ```
2. Chạy lệnh đóng gói:
   ```zsh
   ./dist.sh
   ```

### Kết quả xuất ra:

Sau khi chạy xong, các file phát hành sẽ được lưu tại thư mục **`dist/`**:

| Tên file                               | Mục đích sử dụng                                                                                   |
| :------------------------------------- | :------------------------------------------------------------------------------------------------- |
| **`dist/AI-Gate-Installer.dmg`**       | **(Khuyên dùng)** Bộ cài đặt dạng đĩa ảo kéo-thả chuẩn macOS, tiện lợi nhất để gửi cho người dùng. |
| **`dist/AI-Gate-macOS-Universal.zip`** | File nén zip trực tiếp của `AI Gate.app`.                                                          |

### ✨ Đặc điểm bản build từ `dist.sh`:

- **Universal 2 Binary**: Tương thích và tối ưu hiệu năng 100% cho **cả chip Apple Silicon (M1, M2, M3, M4...) lẫn chip Intel**.
- **Ký mã (Ad-hoc Code Sign)**: Sẵn sàng khởi chạy trên macOS 14.0 (Sonoma) trở lên.

---

## 💻 3. HƯỚNG DẪN CÀI ĐẶT TRÊN MÁY BẢN THÂN

Nếu chỉ muốn cài đặt nhanh phiên bản mới nhất vào thư mục `/Applications` trên máy của bạn:

```zsh
cd /Users/lyquocvan/Downloads/AI-Stack-Native-v7
./Install-AI-Stack.command
```

_(Hoặc click đúp chuột trực tiếp vào file `Install-AI-Stack.command` trong Finder)._

---

## 🛡️ 4. HƯỚNG DẪN DÀNH CHO NGƯỜI NHẬN (TRÊN MÁY MAC KHÁC)

Khi gửi file `AI-Gate-Installer.dmg` cho máy Mac khác tải từ Internet (Google Drive, Zalo, Telegram...), macOS Gatekeeper có thể hiện cảnh báo bảo mật do app chưa đăng ký chứng chỉ doanh nghiệp Apple.

Hãy hướng dẫn người nhận thực hiện **1 trong 2 cách sau** để mở:

### Cách 1: Mở bằng chuột phải (Đơn giản nhất)

1. Mở file `.dmg` và kéo icon **AI Gate** vào thư mục **Applications**.
2. Vào thư mục **Applications**, **chuột phải (hoặc nhấn giữ phím Control + Click)** vào `AI Gate.app` > chọn **Open**.
3. Nhấn nút **Open** trên bảng thông báo hiện ra.

### Cách 2: Xử lý qua Terminal (Nếu bị báo App is damaged / Bị hỏng)

Người nhận chỉ cần mở Terminal trên máy của họ và chạy lệnh:

```zsh
xattr -cr "/Applications/AI Gate.app"
```

---

## 📋 BẢNG TỔNG HỢP CÁC LỆNH NHANH

| Mục đích                           | Lệnh chạy (tại thư mục gốc dự án) |
| :--------------------------------- | :-------------------------------- |
| **Hot-reload khi lập trình**       | `./dev.sh`                        |
| **Build nhanh file .app**          | `./build.sh`                      |
| **Đóng gói phát hành (DMG + ZIP)** | `./dist.sh`                       |
| **Cài đặt vào máy hiện tại**       | `./Install-AI-Stack.command`      |
