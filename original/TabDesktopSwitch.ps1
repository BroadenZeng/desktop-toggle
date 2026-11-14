# =====================================================================
#  TabDesktopSwitch.ps1
#  作用：让「单独按一下 Tab 键」在 虚拟桌面 1 / 桌面 2 之间来回切换。
#
#  用法：双击同目录的「Tab桌面切换开关.bat」即可，本文件不需要手动运行。
#        双击第 1 次 = 开启；再双击一次 = 关闭（Tab 立刻恢复正常）。
#
#  依赖：只用 Windows 自带的 Windows PowerShell 5.1 + .NET，无需安装任何软件。
# =====================================================================

param(
    [switch]$Toggle,
    [switch]$Run,
    [switch]$VerboseHookLog,
    [string]$StateDir = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($StateDir)) {
    $Root = Join-Path $env:LOCALAPPDATA 'TabDesktopSwitcher'
} else {
    $Root = $StateDir
}

$LogFile    = Join-Path $Root 'run.log'
$HookLog    = Join-Path $Root 'hook.log'
$StopFile   = Join-Path $Root 'stop.flag'
$PidFile    = Join-Path $Root 'helper.pid'
$StatusFile = Join-Path $Root 'helper.status'
$MutexName  = 'Local\TabDesktopSwitcher_v1'

function Ensure-Root {
    if (-not (Test-Path -LiteralPath $Root)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
}

function Write-Log([string]$msg) {
    try {
        $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $msg
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch { }
}

# 后台进程是否存活：用命名互斥量判断，进程一退出互斥量自动消失，不会出现假在线
function Test-HelperRunning {
    $m = $null
    try {
        $m = [System.Threading.Mutex]::OpenExisting($MutexName)
        $m.Dispose()
        return $true
    } catch {
        return $false
    }
}

function Show-Balloon([string]$Title, [string]$Text, [int]$Seconds = 3) {
    try {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        Add-Type -AssemblyName System.Drawing | Out-Null
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Information
        $ni.Visible = $true
        $ni.BalloonTipTitle = $Title
        $ni.BalloonTipText = $Text
        $ni.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $ni.ShowBalloonTip($Seconds * 1000)
        $end = (Get-Date).AddSeconds($Seconds + 0.8)
        while ((Get-Date) -lt $end) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 60
        }
        $ni.Visible = $false
        $ni.Dispose()
    } catch {
        Write-Log ('提示显示失败：' + $_.Exception.Message)
    }
}

function Stop-Helper {
    Remove-Item -LiteralPath $StopFile -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $StopFile -Value 'stop' -Encoding ASCII
    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-HelperRunning)) { break }
        Start-Sleep -Milliseconds 120
    }
    if (Test-HelperRunning) {
        Write-Log '关闭：后台进程未响应停止信号，改为强制结束'
        $hp = 0
        if (Test-Path -LiteralPath $PidFile) {
            try { $hp = [int]((Get-Content -LiteralPath $PidFile -Raw).Trim()) } catch { $hp = 0 }
        }
        if ($hp -gt 0) {
            try { Stop-Process -Id $hp -Force -ErrorAction Stop } catch { }
        }
        Start-Sleep -Milliseconds 500
    }
    Remove-Item -LiteralPath $StopFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StatusFile -Force -ErrorAction SilentlyContinue
}

function Start-Helper {
    Remove-Item -LiteralPath $StopFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StatusFile -Force -ErrorAction SilentlyContinue

    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw '未找到 Windows PowerShell（powershell.exe）。' }

    $self = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($self)) { $self = $MyInvocation.MyCommand.Path }
    if ([string]::IsNullOrWhiteSpace($self)) { throw '无法定位脚本自身路径。' }

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $self), '-Run')
    if (-not [string]::IsNullOrWhiteSpace($StateDir)) {
        $argList += @('-StateDir', ('"{0}"' -f $StateDir))
    }
    Start-Process -FilePath $exe -ArgumentList $argList -WindowStyle Hidden

    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $StatusFile) { break }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $StatusFile)) {
        throw ('后台进程启动超时（可能被安全软件拦截）。日志：' + $LogFile)
    }
    $st = (Get-Content -LiteralPath $StatusFile -Raw).Trim()
    if ($st -ne 'ok') {
        throw ('后台进程启动失败：' + $st + '  日志：' + $LogFile)
    }
}

# =====================================================================
#  一、开关模式（双击 BAT 时走这里）
# =====================================================================
if (-not $Run) {
    try {
        Ensure-Root
        if (Test-HelperRunning) {
            Write-Log '开关：检测到功能已开启 → 执行关闭'
            Stop-Helper
            Write-Log '开关：已关闭'
            Show-Balloon 'Tab 桌面切换已关闭' 'Tab 键已恢复正常输入功能。想再开启，重新双击那个 BAT 即可。' 3
        } else {
            Write-Log '开关：检测到功能未开启 → 执行开启'
            Start-Helper
            Write-Log '开关：已开启'
        }
        exit 0
    } catch {
        Write-Log ('开关执行失败：' + $_.Exception.Message)
        try {
            Add-Type -AssemblyName System.Windows.Forms | Out-Null
            [System.Windows.Forms.MessageBox]::Show(
                ('操作失败：' + $_.Exception.Message + [Environment]::NewLine + [Environment]::NewLine + '日志文件：' + $LogFile),
                'Tab 桌面切换', 'OK', 'Error') | Out-Null
        } catch { }
        exit 1
    }
}

# =====================================================================
#  二、后台常驻模式（由开关模式拉起，-Run）
# =====================================================================
Ensure-Root
$Mutex = New-Object System.Threading.Mutex($false, $MutexName)
Set-Content -LiteralPath $PidFile -Value ([string]$PID) -Encoding ASCII
Write-Log ('后台：启动，PID=' + $PID)

$hookInstalled = $false
$trayIcon = $null

try {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Add-Type -AssemblyName System.Drawing | Out-Null

    $cs = @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;
using Microsoft.Win32;

public class TabDesk
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const uint VK_TAB = 0x09;
    private const string VDK_PATH = @"Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops";

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    private delegate IntPtr LowLevelProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")]
    private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    private static IntPtr _hook = IntPtr.Zero;
    private static LowLevelProc _proc = null;
    private static bool _tabHeld = false;

    public static volatile bool Pending = false;
    public static volatile bool Verbose = false;
    public static string LogPath = "";
    public static string HookError = "";

    public static bool Install()
    {
        try
        {
            _proc = new LowLevelProc(Callback);
            _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(null), 0);
            if (_hook == IntPtr.Zero)
            {
                HookError = "SetWindowsHookEx 失败，错误码 " + Marshal.GetLastWin32Error();
                return false;
            }
            return true;
        }
        catch (Exception ex)
        {
            HookError = ex.GetType().Name + ": " + ex.Message;
            return false;
        }
    }

    public static void Uninstall()
    {
        if (_hook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }
        _proc = null;
        _tabHeld = false;
    }

    private static void Trace(string s)
    {
        if (!Verbose || LogPath == null || LogPath.Length == 0) return;
        try
        {
            FileStream fs = new FileStream(LogPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
            StreamWriter sw = new StreamWriter(fs, Encoding.UTF8);
            sw.WriteLine(DateTime.Now.ToString("HH:mm:ss.fff") + "  " + s);
            sw.Flush();
            sw.Dispose();
            fs.Dispose();
        }
        catch { }
    }

    private static IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) return CallNextHookEx(_hook, nCode, wParam, lParam);

        KBDLLHOOKSTRUCT info = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
        if (info.vkCode != VK_TAB) return CallNextHookEx(_hook, nCode, wParam, lParam);

        long msg = wParam.ToInt64();

        if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN)
        {
            if (ModifierDown())
            {
                _tabHeld = false;
                Trace("Tab 带修饰键，放行");
                return CallNextHookEx(_hook, nCode, wParam, lParam);
            }
            if (!_tabHeld)
            {
                _tabHeld = true;
                Pending = true;
                Trace("Tab 命中：已拦截");
            }
            return new IntPtr(1);
        }

        if (msg == WM_KEYUP || msg == WM_SYSKEYUP)
        {
            bool mine = _tabHeld;
            _tabHeld = false;
            if (mine)
            {
                Trace("Tab 抬起：已拦截");
                return new IntPtr(1);
            }
            return CallNextHookEx(_hook, nCode, wParam, lParam);
        }

        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    private static bool ModifierDown()
    {
        int[] keys = new int[] { 0x11, 0x12, 0x10, 0x5B, 0x5C };
        for (int i = 0; i < keys.Length; i++)
        {
            if ((GetAsyncKeyState(keys[i]) & 0x8000) != 0) return true;
        }
        return false;
    }

    public static int DesktopCount()
    {
        try
        {
            RegistryKey key = Registry.CurrentUser.OpenSubKey(VDK_PATH);
            if (key == null) return 0;
            object v = key.GetValue("VirtualDesktopIDs");
            key.Close();
            if (!(v is byte[])) return 0;
            return ((byte[])v).Length / 16;
        }
        catch { return 0; }
    }

    private static Guid Slice(byte[] data, int offset)
    {
        byte[] tmp = new byte[16];
        Array.Copy(data, offset, tmp, 0, 16);
        return new Guid(tmp);
    }

    public static int CurrentIndex()
    {
        try
        {
            RegistryKey key = Registry.CurrentUser.OpenSubKey(VDK_PATH);
            if (key == null) return -1;
            object vIds = key.GetValue("VirtualDesktopIDs");
            object vCur = key.GetValue("CurrentVirtualDesktop");
            key.Close();
            if (vIds == null || vCur == null) return -1;
            if (!(vIds is byte[])) return -1;
            byte[] ids = (byte[])vIds;

            Guid cur;
            if (vCur is byte[])
            {
                byte[] b = (byte[])vCur;
                if (b.Length < 16) return -1;
                cur = Slice(b, 0);
            }
            else if (vCur is string)
            {
                try { cur = new Guid((string)vCur); }
                catch { return -1; }
            }
            else
            {
                return -1;
            }

            int n = ids.Length / 16;
            for (int i = 0; i < n; i++)
            {
                if (Slice(ids, i * 16).Equals(cur)) return i;
            }
            return -1;
        }
        catch { return -1; }
    }

    public static string SwitchDesktop()
    {
        int count = DesktopCount();
        if (count < 2) return "only-one";
        int idx = CurrentIndex();
        if (idx < 0) idx = 0;
        if (idx == 0) SendShellHotkey(0x27);
        else SendShellHotkey(0x25);
        return "ok|count=" + count + "|from=" + idx;
    }

    public static string CreateNewDesktop()
    {
        SendShellHotkey(0x44);
        return "created";
    }

    private static void SendShellHotkey(byte vk)
    {
        keybd_event(0x5B, 0, 0, UIntPtr.Zero);
        Thread.Sleep(12);
        keybd_event(0xA2, 0, 0, UIntPtr.Zero);
        Thread.Sleep(12);
        keybd_event(vk, 0, 0, UIntPtr.Zero);
        Thread.Sleep(12);
        keybd_event(vk, 0, 2, UIntPtr.Zero);
        Thread.Sleep(12);
        keybd_event(0xA2, 0, 2, UIntPtr.Zero);
        Thread.Sleep(12);
        keybd_event(0x5B, 0, 2, UIntPtr.Zero);
        Thread.Sleep(12);
    }
}
'@

    Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop
    [TabDesk]::Verbose = [bool]$VerboseHookLog.IsPresent
    [TabDesk]::LogPath = $HookLog

    $hookInstalled = [TabDesk]::Install()
    if (-not $hookInstalled) {
        Set-Content -LiteralPath $StatusFile -Value ('error|键盘钩子安装失败：' + [TabDesk]::HookError) -Encoding UTF8
        Write-Log ('后台：键盘钩子安装失败：' + [TabDesk]::HookError)
        exit 1
    }

    $deskCount = [TabDesk]::DesktopCount()
    Write-Log ('后台：检测到虚拟桌面数量 = ' + $deskCount)
    if ($deskCount -lt 2) {
        Write-Log '后台：当前只有 1 个虚拟桌面，自动新建「桌面 2」'
        [TabDesk]::CreateNewDesktop()
        Start-Sleep -Milliseconds 1000
        $deskCount = [TabDesk]::DesktopCount()
        Write-Log ('后台：新建后虚拟桌面数量 = ' + $deskCount)
    }

    $trayIcon = New-Object System.Windows.Forms.NotifyIcon
    $trayIcon.Icon = [System.Drawing.SystemIcons]::Information
    $trayIcon.Visible = $true
    $trayIcon.Text = 'Tab 切换虚拟桌面：已开启'
    $trayIcon.BalloonTipTitle = 'Tab 桌面切换已开启'
    $trayIcon.BalloonTipText = '现在单独按一下 Tab，就能在「桌面 1 / 桌面 2」之间来回切换。Alt+Tab、Shift+Tab、Ctrl+Tab 照常可用。要关闭功能，再双击一次那个 BAT。'
    $trayIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $trayIcon.ShowBalloonTip(5000)

    Set-Content -LiteralPath $StatusFile -Value 'ok' -Encoding ASCII
    Write-Log '后台：已就绪，Tab 键已接管'

    $counter = 0
    while ($true) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 10

        if ([TabDesk]::Pending) {
            [TabDesk]::Pending = $false
            $res = [TabDesk]::SwitchDesktop()
            Write-Log ('后台：按 Tab 切换 → ' + $res)
            if ($res -eq 'only-one') {
                [TabDesk]::CreateNewDesktop()
                Start-Sleep -Milliseconds 800
                Write-Log ('后台：检测到仅 1 个桌面，已自动新建，当前数量 ' + [TabDesk]::DesktopCount())
            }
        }

        $counter++
        if ($counter -ge 50) {
            $counter = 0
            if (Test-Path -LiteralPath $StopFile) { break }
        }
    }
    Write-Log '后台：收到停止信号，正在退出'
}
catch {
    Write-Log ('后台：异常 ' + $_.Exception.Message)
    try {
        Set-Content -LiteralPath $StatusFile -Value ('error|' + $_.Exception.Message) -Encoding UTF8
    } catch { }
}
finally {
    try { if ($hookInstalled) { [TabDesk]::Uninstall() } } catch { }
    try {
        if ($trayIcon -ne $null) {
            $trayIcon.Visible = $false
            $trayIcon.Dispose()
        }
    } catch { }
    try { $Mutex.Dispose() } catch { }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StatusFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StopFile -Force -ErrorAction SilentlyContinue
    Write-Log '后台：已退出'
}

exit 0
