## 编译环境

本项目使用 **Zig** 编写，开发与编译环境如下：

- **编程语言：** Zig
- **Zig 版本：** 0.15.2
- **开发平台：** Windows 11
- **编译目标：** Windows x64


## 编译方法

确保已安装 Zig 0.15.2，并在项目目录下打开终端运行：

```powershell
zig build-exe main.zig -lc -lws2_32 -liphlpapi -O ReleaseSmall -femit-bin=QuickShare.exe
