# DesktopToggle · 一键切换虚拟桌面

轻量的虚拟桌面切换工具。按一个键，在学习、工作和个人桌面之间快速切换。默认按键为 Tab，也可以改成其他单键。

## 下载

直接下载 [下载最新版 DesktopToggle.exe](https://github.com/BroadenZeng/desktop-toggle/raw/refs/heads/main/download/DesktopToggle.exe)。也可查看 [发布页面](https://github.com/BroadenZeng/desktop-toggle/releases)。

下载后双击运行，再次双击可退出。无需安装或管理员权限。请勿同时运行旧版。

SHA-256：`EDB3C125430307B90E20DB2575C50784E181AE67F7FEC72185AEA2ED63173399`

## 使用

1. 双击运行下载的 EXE。启用后会显示主窗口。
2. 按 Tab 切换桌面；如果只有一个桌面，程序会尝试自动创建第二个。
3. 修改按键：点击“更改”，直接按下新键，再点击“保存”。例如可以选 F8 或 Caps Lock。仅支持单键，Ctrl、Alt、Shift 和 Win 不能单独作为触发键。
4. 需要收起工具窗口时，可在“本工具移至”中选择不需要展示工具的虚拟桌面。程序会尝试将工具窗口移到所选桌面，并同时切换过去；切回其他桌面后，工具窗口便不会显示。
5. “工具状态”可关闭或开启切换功能。可将窗口最小化到任务栏，工具继续运行；关闭窗口或再次双击 EXE 可退出程序。

启用期间，触发键的单独按下会被占用；默认 Tab 不再用于普通焦点切换和缩进。带修饰键的组合如 Alt+Tab 会放行。关闭程序不会删除虚拟桌面。

## 注意事项

- 使用系统自带 .NET Framework 4.x，无需安装其他运行时。
- 程序未签名，下载后 Windows SmartScreen 可能显示提示。请从可信来源下载。
- 程序读取 Explorer 的虚拟桌面状态，并使用 Windows 桌面快捷键切换。由于依赖的状态信息并非公开接口，Windows 更新可能影响兼容性；无法读取状态或确认切换时会停止接管按键。
- 默认按当前桌面顺序在前两个桌面之间切换；从其他桌面触发时返回第一个桌面。
- 旧版桌面切换脚本或其他键盘工具可能拦截同一个按键，请勿同时运行。
- 配置保存在 `%LOCALAPPDATA%\DesktopToggle\hotkey.txt`，最后一次错误保存在同目录的 `last-error.txt`。程序不记录按键内容，也不设置开机启动。
- 卸载时先关闭程序，再删除 EXE；如需清除设置，可删除上述配置目录。

## 系统兼容性与验证

在 Windows 11 21H2（22000.2538）上，早期版本已验证从一个桌面创建第二个桌面、桌面间切换以及启动和关闭。后续调整了界面和按键录入，最新版的最小化、完整键盘交互及其他 Windows 版本尚待验证。详见 [测试记录](TEST-REPORT.md)。

## 问题反馈

遇到问题或有改进建议，请在 [Issues](https://github.com/BroadenZeng/desktop-toggle/issues) 提交，附上 Windows 版本和复现步骤。

## 构建

在 Windows PowerShell 中运行：

```powershell
powershell -NoProfile -File .\build.ps1
```

编译后生成 `DesktopToggle.exe`。源码位于 `src/`。项目使用 MIT 许可证，参见 [LICENSE](LICENSE)。实现方案与早期脚本说明见 [NOTICE.md](NOTICE.md)。

参考：[键盘钩子](https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelkeyboardproc)、[SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)。









