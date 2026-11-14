<#
  桌面 Tab 切换（Win11）
  ------------------------------------------------------------------
  入口：双击同目录下的「桌面Tab切换.cmd」——双击一次开启，再双击一次关闭。
  开启后：单按一下 Tab，就在「桌面 1 / 桌面 2」之间来回切。
         Alt+Tab、Ctrl+Tab、Shift+Tab 不受影响（带修饰键的 Tab 一律放过）。

  只用 Windows 自带的 PowerShell 5.1 + .NET Framework 自带编译器，不安装任何第三方软件。

  实现思路（Windows 没有公开的"切换虚拟桌面"API）：
    1. Add-Type 现场编译一小段 C#（系统自带编译器，不下载任何东西）
    2. SetWindowsHookEx 装低级键盘钩子，拦下"裸 Tab"
    3. 拦到后模拟 Ctrl+Win+←/→（Win11 官方切换快捷键）来切桌面
    4. 用注册表 HKCU\...\Explorer\VirtualDesktops 里的 VirtualDesktopIDs /
       CurrentVirtualDesktop 判断"现在在第几张桌面、总共几张"，
       所以能精确切到桌面 1 或 2，切错了也立刻知道

  参数（正常使用不需要传）：
    -Toggle    开 / 关 切换（默认）
    -Run       引擎模式（被 -Toggle 以隐藏窗口拉起，前台别直接用）
    -SelfTest  自检：读桌面数量与当前索引，并真的往右切一次、再切回来
#>

[CmdletBinding()]
param(
    [switch]$Toggle,
    [switch]$Run,
    [switch]$SelfTest
)

$scriptPath = $PSCommandPath
if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }

$stateDir = Join-Path $env:LOCALAPPDATA 'DeskTabSwitch'
$pidFile  = Join-Path $stateDir 'engine.pid'
$logFile  = Join-Path $stateDir 'engine.log'

if (-not ($Toggle -or $Run -or $SelfTest)) { $Toggle = $true }

# ------------------------------------------------------------------
#  C# 源码（低级键盘钩子 + 按键注入 + 桌面索引探测）
# ------------------------------------------------------------------
$csharp = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace DeskTabSwitch
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct KBDLLHOOKSTRUCT
    {
        public int vkCode;
        public int scanCode;
        public int flags;
        public int time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public int time;
        public int ptX;
        public int ptY;
        public uint lPrivate;
    }

    public static class Engine
    {
        private const int WH_KEYBOARD_LL   = 13;
        private const int WM_KEYDOWN       = 0x0100;
        private const int WM_KEYUP         = 0x0101;
        private const int WM_SYSKEYDOWN    = 0x0104;
        private const int WM_SYSKEYUP      = 0x0105;

        private const int VK_TAB           = 0x09;
        private const int VK_SHIFT         = 0x10;
        private const int VK_CONTROL       = 0x11;
        private const int VK_MENU          = 0x12;   // Alt
        private const int VK_LEFT          = 0x25;
        private const int VK_RIGHT         = 0x27;
        private const int VK_LWIN          = 0x5B;
        private const int VK_RWIN          = 0x5C;
        private const int VK_LCONTROL      = 0xA2;

        private const int KEYEVENTF_KEYUP       = 0x0002;
        private const int KEYEVENTF_EXTENDEDKEY = 0x0001;

        private const uint MB_OK               = 0x00000000;
        private const uint MB_ICONINFORMATION  = 0x00000040;
        private const uint MB_ICONWARNING      = 0x00000030;
        private const uint MB_TOPMOST          = 0x00040000;
        private const uint MB_SETFOREGROUND    = 0x00010000;

        private const string VD_KEY = @"Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops";

        private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);

        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
        private static extern IntPtr GetModuleHandle(string lpModuleName);

        [DllImport("user32.dll")]
        private static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

        [DllImport("user32.dll")]
        private static extern bool TranslateMessage(ref MSG lpMsg);

        [DllImport("user32.dll")]
        private static extern IntPtr DispatchMessage(ref MSG lpMsg);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int vKey);

        [DllImport("user32.dll")]
        private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, IntPtr dwExtraInfo);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

        [DllImport("user32.dll")]
        private static extern bool MessageBeep(uint uType);

        private static IntPtr hookId = IntPtr.Zero;
        private static LowLevelKeyboardProc hookProc = null;
        private static Thread worker = null;
        private static readonly AutoResetEvent trigger = new AutoResetEvent(false);
        private static volatile bool busy = false;
        private static volatile int desktopCount = 2;
        private static bool swallowTabUp = false;
        private static int nextDir = VK_RIGHT;
        private static string logPath = null;
        private static readonly object logLock = new object();

        public static void SetLog(string path) { logPath = path; }

        private static void Log(string msg)
        {
            try
            {
                if (string.IsNullOrEmpty(logPath)) return;
                lock (logLock)
                {
                    try
                    {
                        FileInfo fi = new FileInfo(logPath);
                        if (fi.Exists && fi.Length > 512 * 1024) File.Delete(logPath);
                    }
                    catch { }
                    File.AppendAllText(logPath,
                        DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + msg + Environment.NewLine,
                        new UTF8Encoding(false));
                }
            }
            catch { }
        }

        private static string DirName(int dir) { return dir == VK_RIGHT ? "Win+Ctrl+->" : "Win+Ctrl+<-"; }

        private static int Opposite(int dir) { return dir == VK_RIGHT ? VK_LEFT : VK_RIGHT; }

        // 从注册表读出：桌面总数 + 当前桌面索引（0 基）
        private static bool QueryDesk(out int count, out int index)
        {
            count = 0;
            index = -1;
            try
            {
                using (Microsoft.Win32.RegistryKey k =
                       Microsoft.Win32.Registry.CurrentUser.OpenSubKey(VD_KEY, false))
                {
                    if (k == null) return false;
                    byte[] ids = k.GetValue("VirtualDesktopIDs") as byte[];
                    byte[] cur = k.GetValue("CurrentVirtualDesktop") as byte[];
                    if (ids == null || cur == null) return false;
                    if (ids.Length < 16 || (ids.Length % 16) != 0 || cur.Length < 16) return false;

                    count = ids.Length / 16;
                    for (int i = 0; i < count; i++)
                    {
                        bool same = true;
                        for (int j = 0; j < 16; j++)
                        {
                            if (ids[i * 16 + j] != cur[j]) { same = false; break; }
                        }
                        if (same) { index = i; break; }
                    }
                    return true;
                }
            }
            catch { return false; }
        }

        public static bool Init()
        {
            try
            {
                int c, i;
                desktopCount = QueryDesk(out c, out i) ? c : 2;

                worker = new Thread(WorkerLoop);
                worker.SetApartmentState(ApartmentState.STA);
                worker.IsBackground = true;
                worker.Start();

                hookProc = HookCallback;
                hookId = SetWindowsHookEx(WH_KEYBOARD_LL, hookProc, GetModuleHandle(null), 0);
                if (hookId == IntPtr.Zero)
                {
                    Log("init: 键盘钩子安装失败，Win32 错误码 " + Marshal.GetLastWin32Error());
                    return false;
                }

                Log("init: 就绪（桌面总数 " + desktopCount + "）");
                return true;
            }
            catch (Exception ex)
            {
                Log("init: 异常 " + ex);
                return false;
            }
        }

        public static void Pump()
        {
            MSG msg;
            while (true)
            {
                int r = GetMessage(out msg, IntPtr.Zero, 0, 0);
                if (r == 0) break;                       // WM_QUIT
                if (r == -1) { Thread.Sleep(100); continue; }
                TranslateMessage(ref msg);
                DispatchMessage(ref msg);
            }
        }

        public static void Shutdown()
        {
            try { if (hookId != IntPtr.Zero) { UnhookWindowsHookEx(hookId); hookId = IntPtr.Zero; } } catch { }
        }

        private static void WorkerLoop()
        {
            int c, i;
            if (QueryDesk(out c, out i)) desktopCount = c;

            while (true)
            {
                bool signaled = trigger.WaitOne(2000);
                // 顺带刷新桌面总数（用户可能新建 / 关闭了桌面）
                if (QueryDesk(out c, out i)) desktopCount = c;
                if (!signaled) continue;
                try { DoToggle(); }
                catch (Exception ex) { Log("worker: 切换异常 " + ex.Message); }
            }
        }

        private static bool AnyModifierDown()
        {
            return (GetAsyncKeyState(VK_SHIFT)   & 0x8000) != 0
                || (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0
                || (GetAsyncKeyState(VK_MENU)    & 0x8000) != 0
                || (GetAsyncKeyState(VK_LWIN)    & 0x8000) != 0
                || (GetAsyncKeyState(VK_RWIN)    & 0x8000) != 0;
        }

        private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            try
            {
                if (nCode >= 0)
                {
                    int wm = wParam.ToInt32();
                    bool isDown = (wm == WM_KEYDOWN || wm == WM_SYSKEYDOWN);
                    bool isUp = (wm == WM_KEYUP || wm == WM_SYSKEYUP);

                    if (isDown || isUp)
                    {
                        KBDLLHOOKSTRUCT k = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
                        if (k.vkCode == VK_TAB)
                        {
                            if (isDown)
                            {
                                // 只有一张桌面时没得切，就别吞 Tab，让 Tab 照常干活
                                if (desktopCount < 2) return CallNextHookEx(hookId, nCode, wParam, lParam);

                                if (!AnyModifierDown())
                                {
                                    swallowTabUp = true;
                                    if (!busy) trigger.Set();
                                    return (IntPtr)1;         // 吞掉裸 Tab
                                }
                            }
                            else if (swallowTabUp)
                            {
                                swallowTabUp = false;
                                return (IntPtr)1;              // 连抬键一起吞掉
                            }
                        }
                    }
                }
            }
            catch { }
            return CallNextHookEx(hookId, nCode, wParam, lParam);
        }

        private static void SendCtrlWin(int dir)
        {
            keybd_event(VK_LCONTROL, 0, 0, IntPtr.Zero);
            Thread.Sleep(8);
            keybd_event(VK_LWIN, 0, 0, IntPtr.Zero);
            Thread.Sleep(8);
            keybd_event((byte)dir, 0, KEYEVENTF_EXTENDEDKEY, IntPtr.Zero);
            Thread.Sleep(8);
            keybd_event((byte)dir, 0, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP, IntPtr.Zero);
            Thread.Sleep(8);
            keybd_event(VK_LWIN, 0, KEYEVENTF_KEYUP, IntPtr.Zero);
            Thread.Sleep(8);
            keybd_event(VK_LCONTROL, 0, KEYEVENTF_KEYUP, IntPtr.Zero);
        }

        // 按一次切换键，等桌面索引变化；成功返回新索引，失败返回 -1
        private static int PressAndWait(int dir, int curIndex, int waitMs)
        {
            SendCtrlWin(dir);
            Stopwatch sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < waitMs)
            {
                Thread.Sleep(45);
                int count, idx;
                if (QueryDesk(out count, out idx) && idx >= 0 && idx != curIndex) return idx;
            }
            return -1;
        }

        private static void ShowBox(string text, uint icon)
        {
            MessageBeep(0x30);   // 警告音
            MessageBoxW(IntPtr.Zero, text, "桌面 Tab 切换",
                        MB_OK | icon | MB_TOPMOST | MB_SETFOREGROUND);
        }

        private static void DoToggle()
        {
            busy = true;
            try
            {
                int count, idx;
                if (!QueryDesk(out count, out idx) || idx < 0)
                {
                    // 读不到桌面信息时退化成"左右交替盲切"
                    int dir = nextDir;
                    SendCtrlWin(dir);
                    Thread.Sleep(400);
                    nextDir = Opposite(dir);
                    Log("switch: 读不到桌面索引，盲切 " + DirName(dir));
                    return;
                }

                desktopCount = count;

                if (count < 2)
                {
                    Log("switch: 只有 " + count + " 张桌面");
                    ShowBox("当前只有 1 张虚拟桌面，没得切。\n\n新建一张：按 Win+Ctrl+D，或者 Win+Tab 打开任务视图点「新建桌面」。",
                            MB_ICONINFORMATION);
                    return;
                }

                // 目标：始终在「桌面 1」和「桌面 2」之间来回
                int target = (idx == 0) ? 1 : 0;
                if (target >= count) target = count - 1;

                int cur = idx;
                int steps = 0;
                while (cur != target && steps < 6)
                {
                    int dir = (target > cur) ? VK_RIGHT : VK_LEFT;
                    int nxt = PressAndWait(dir, cur, 900);
                    if (nxt < 0) break;
                    cur = nxt;
                    steps++;
                }

                if (cur == target)
                {
                    nextDir = (target == 0) ? VK_RIGHT : VK_LEFT;
                    Log("switch ok: 现在在 桌面" + (cur + 1) + "（共 " + count + " 张）");
                }
                else
                {
                    Log("switch failed: 停在 桌面" + (cur + 1));
                    ShowBox("按键没生效，桌面没动。\n\n多半是当前前台窗口属于「管理员权限」的程序，Windows 会拦掉这种模拟按键。\n点一下普通窗口（或桌面空白处）再按 Tab 试试。",
                            MB_ICONWARNING);
                }
            }
            finally
            {
                busy = false;
            }
        }

        // 自检：读桌面信息 → 往右切一次 → 切回来
        public static string SelfTest()
        {
            StringBuilder sb = new StringBuilder();
            int count, idx;
            bool ok = QueryDesk(out count, out idx);
            sb.AppendLine("注册表读取桌面信息: " + (ok ? "OK" : "失败"));
            if (!ok) { sb.AppendLine("=> 无法判断当前桌面，工具会退化成盲切"); return sb.ToString(); }

            sb.AppendLine("桌面总数 = " + count + "，当前索引 = " + idx + "（即「桌面" + (idx + 1) + "」）");
            if (count < 2)
            {
                sb.AppendLine("=> 只有 1 张桌面，没法测切换（先按 Win+Ctrl+D 新建一张）");
                return sb.ToString();
            }

            int n1 = PressAndWait(VK_RIGHT, idx, 1500);
            if (n1 < 0)
            {
                sb.AppendLine("Ctrl+Win+-> : 索引没变（按键可能被前台的管理员权限窗口拦掉了）");
                return sb.ToString();
            }
            sb.AppendLine("Ctrl+Win+-> : 切到索引 " + n1 + "（切换成功）");

            int n2 = PressAndWait(VK_LEFT, n1, 1500);
            if (n2 == idx) sb.AppendLine("Ctrl+Win+<- : 已回到索引 " + n2 + "（原桌面）");
            else sb.AppendLine("Ctrl+Win+<- : 索引=" + n2 + "，没回到原桌面！");
            return sb.ToString();
        }
    }
}
'@

# ------------------------------------------------------------------
#  状态查询 / 启停
# ------------------------------------------------------------------
function Get-DesktopInfo {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops')
    if (-not $k) { return $null }
    try {
        $ids = $k.GetValue('VirtualDesktopIDs')
        $cur = $k.GetValue('CurrentVirtualDesktop')
    }
    finally { $k.Close() }
    if (-not $ids -or -not $cur) { return $null }
    $count = [int]($ids.Length / 16)
    $index = -1
    for ($i = 0; $i -lt $count; $i++) {
        if ([BitConverter]::ToString($ids, $i * 16, 16) -eq [BitConverter]::ToString($cur, 0, 16)) { $index = $i; break }
    }
    return [pscustomobject]@{ Count = $count; Index = $index }
}

function Initialize-State {
    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
}

function Get-EngineProcess {
    if (-not (Test-Path -LiteralPath $pidFile)) { return $null }
    $text = ''
    try { $text = [IO.File]::ReadAllText($pidFile) } catch { return $null }
    if (-not $text) { return $null }
    $procId = 0
    if (-not [int]::TryParse($text.Trim(), [ref]$procId)) { return $null }
    if ($procId -le 4) { return $null }
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $proc) { return $null }
    # 防止 PID 被别的程序复用时误杀
    $ci = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $procId" -ErrorAction SilentlyContinue
    if ($ci -and $ci.CommandLine -and $ci.CommandLine -like '*DesktopTabSwitch.ps1*') { return $proc }
    return $null
}

function Start-Engine {
    Initialize-State
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

    $argList = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $scriptPath + '" -Run'
    Start-Process -FilePath $psExe -ArgumentList $argList -WindowStyle Hidden | Out-Null

    # 首次要现场编译 C#，给足 30 秒
    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep -Milliseconds 250
        $p = Get-EngineProcess
        if ($p) { return $p }
    }
    return $null
}

function Toggle-Switcher {
    Initialize-State
    $engine = Get-EngineProcess

    if ($engine) {
        Stop-Process -Id $engine.Id -Force -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt 15; $i++) {
            if (-not (Get-Process -Id $engine.Id -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 100
        }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        try { [System.Media.SystemSounds]::Beep.Play() } catch {}
        Write-Host ''
        Write-Host '  [已关闭]  Tab 键已恢复正常。' -ForegroundColor Yellow
        Write-Host ''
        Start-Sleep -Milliseconds 1200
        return
    }

    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '  正在启动...' -ForegroundColor DarkGray
    $p = Start-Engine

    if ($p) {
        try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
        Write-Host ''
        Write-Host '  [已开启]' -ForegroundColor Green -NoNewline
        Write-Host '  现在单按 Tab：在「桌面 1 <-> 桌面 2」之间来回切。' -ForegroundColor Gray
        Write-Host '             Alt+Tab / Ctrl+Tab / Shift+Tab 不受影响。' -ForegroundColor DarkGray
        Write-Host '             再双击一次本文件即可关闭。' -ForegroundColor DarkGray

        $info = Get-DesktopInfo
        if ($info -and $info.Count -lt 2) {
            Write-Host ''
            Write-Host '  [提示] 当前只有 1 张虚拟桌面，按 Tab 不会有反应。' -ForegroundColor Yellow
            Write-Host '         先按 Win+Ctrl+D 新建一张（或 Win+Tab 在任务视图里点「新建桌面」）。' -ForegroundColor DarkYellow
        }
        Write-Host ''
    }
    else {
        Write-Host ''
        Write-Host '  [开启失败]  后台引擎没起来。' -ForegroundColor Red
        if (Test-Path -LiteralPath $logFile) {
            $log = Get-Content -LiteralPath $logFile -Raw -ErrorAction SilentlyContinue
            if ($log) {
                Write-Host '  日志：' -ForegroundColor DarkGray
                Write-Host $log.Trim() -ForegroundColor DarkGray
            }
        }
        Write-Host ''
    }
    Start-Sleep -Milliseconds 1500
}

function Start-EngineHost {
    Initialize-State
    try {
        if (-not ('DeskTabSwitch.Engine' -as [type])) {
            Add-Type -TypeDefinition $csharp -Language CSharp -ErrorAction Stop
        }
    }
    catch {
        try { [IO.File]::WriteAllText($logFile, 'Add-Type 编译失败：' + $_.Exception.Message, (New-Object Text.UTF8Encoding $false)) } catch {}
        exit 3
    }

    [DeskTabSwitch.Engine]::SetLog($logFile)

    if (-not [DeskTabSwitch.Engine]::Init()) {
        try { [IO.File]::AppendAllText($logFile, "引擎初始化失败，退出。`r`n", (New-Object Text.UTF8Encoding $false)) } catch {}
        [DeskTabSwitch.Engine]::Shutdown()
        exit 4
    }

    try { [IO.File]::WriteAllText($pidFile, [string]$PID, (New-Object Text.UTF8Encoding $false)) } catch {}

    try {
        [DeskTabSwitch.Engine]::Pump()
    }
    finally {
        [DeskTabSwitch.Engine]::Shutdown()
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-SelfTest {
    try {
        if (-not ('DeskTabSwitch.Engine' -as [type])) {
            Add-Type -TypeDefinition $csharp -Language CSharp -ErrorAction Stop
        }
    }
    catch {
        Write-Host 'Add-Type 编译失败:' -ForegroundColor Red
        Write-Host $_.Exception.Message
        return
    }
    Write-Host ([DeskTabSwitch.Engine]::SelfTest())
}

# ------------------------------------------------------------------
#  分发
# ------------------------------------------------------------------
if ($SelfTest) { Invoke-SelfTest; return }
if ($Run)      { Start-EngineHost; return }
Toggle-Switcher
