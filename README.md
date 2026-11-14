# DesktopToggle

Windows 11 虚拟桌面切换工具。双击开启，按一个键在桌面 1 和桌面 2 之间切换；再次双击关闭。默认按键为 Tab，可在窗口中改成其他单键。

## 使用

1. 从 Releases 下载 `DesktopToggle.exe`，双击运行。启用后会显示主窗口。
2. 按 Tab 切换桌面；如果只有一个桌面，程序会尝试自动创建第二个。
3. 修改按键：点击“更改”，直接按下新键，再点击“保存”。例如可以选 F8 或 Caps Lock。仅支持单键，Ctrl、Alt、Shift 和 Win 不能单独作为触发键。
4. 在“本工具移至”中选择现有桌面，程序尝试将窗口移到该桌面并切换过去。
5. “工具状态”可关闭或开启切换功能。关闭窗口或再次双击 EXE 可退出程序。

启用期间，触发键的单独按下会被占用；默认 Tab 不再用于普通焦点切换和缩进。带修饰键的组合如 Alt+Tab 会放行。关闭程序不会删除虚拟桌面。

## 系统要求与注意事项

- Windows 11 x64，使用系统自带 .NET Framework 4.x，无需安装其他运行时。
- 程序未签名，下载后 Windows SmartScreen 可能显示提示。请从可信来源下载。
- 程序读取 Explorer 的虚拟桌面状态，并使用 Windows 桌面快捷键切换。由于依赖的状态信息并非公开接口，Windows 更新可能影响兼容性；无法读取状态或确认切换时会停止接管按键。
- 默认按当前桌面顺序在前两个桌面之间切换；从其他桌面触发时返回第一个桌面。
- 旧版桌面切换脚本或其他键盘工具可能拦截同一个按键，请勿同时运行。
- 配置保存在 `%LOCALAPPDATA%\DesktopToggle\hotkey.txt`，最后一次错误保存在同目录的 `last-error.txt`。程序不记录按键内容，也不设置开机启动。
- 卸载时先关闭程序，再删除 EXE；如需清除设置，可删除上述配置目录。

## 验证情况

在 Windows 11 21H2（22000.2538）上，早期版本已验证从一个桌面创建第二个桌面、桌面间切换以及启动和关闭。后续调整了界面和按键录入，最新版的完整键盘交互及其他 Windows 版本尚待验证。详见 [测试记录](TEST-REPORT.md)。

## 构建

在 Windows PowerShell 中运行：

```powershell
powershell -NoProfile -File .\build.ps1
```

编译后生成 `DesktopToggle.exe`。源码位于 `src/`。项目使用 MIT 许可证，参见 [LICENSE](LICENSE)。实现方案与早期脚本说明见 [NOTICE.md](NOTICE.md)。

参考：[键盘钩子](https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelkeyboardproc)、[SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)。

