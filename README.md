# NTRMAN Gallery Unlocker

Tool tự động tìm kiếm và mở khóa toàn bộ CG / Scene Gallery cho các game Unity sử dụng Naninovel của NTRMAN.

## Tính năng

- Tự động quét các ổ đĩa và thư mục tìm game Naninovel tương thích.
- Hỗ trợ cả 2 cơ chế gallery hook:
  - `UnlockableCustom`: Ghi trực tiếp các biến cờ unlock.
  - `GalleryThumbnail`: Ép trạng thái mở khóa và gọi sự kiện mở khóa `UnityEvent`.
- Hỗ trợ cả game Unity 32-bit (x86) và 64-bit (x64) với BepInEx 5 đi kèm.
- Ghi vào file lưu toàn cục (`GlobalSave.nson`) để giữ trạng thái mở khóa vĩnh viễn.

## Cách sử dụng

1. Chạy `RUN.cmd` và chọn tùy chọn quét hoặc kéo thả thư mục game vào.
2. Hoặc chạy trực tiếp qua PowerShell:
   ```powershell
   .\GalleryUnlock.ps1 -Path "D:\Games\TenGame" -Launch
   ```

## Build từ Source

Yêu cầu .NET SDK:
```cmd
dotnet build -c Release
```
Quá trình build Release sẽ tự động chạy Obfuscar để làm rối code của `GalleryUnlockPlugin.dll`.
