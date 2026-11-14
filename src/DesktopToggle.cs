using System;
using System.IO;
using System.Drawing;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace DesktopToggle {
static class Native {
    public delegate IntPtr HookProc(int code, IntPtr msg, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] public struct KeyData { public uint key, scan, flags, time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] public struct Keyboard { public ushort key, scan; public uint flags, time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Explicit, Size=32)] public struct InputUnion { [FieldOffset(0)] public Keyboard keyboard; }
    [StructLayout(LayoutKind.Sequential)] public struct Input { public uint type; public InputUnion data; }
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr module, uint thread);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr msg, IntPtr data);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint count, Input[] input, int size);
    public static bool Down(int k) { return (GetAsyncKeyState(k) & 0x8000) != 0; }
    public static int Modifiers() { return (Down(17)?1:0)|(Down(18)?2:0)|(Down(16)?4:0)|((Down(91)||Down(92))?8:0); }
    public static void ShellKey(int key) {
        // One complete batch avoids sleeps between synthetic modifier down/up events.
        int[] keys={91,162,key,key,162,91}; var inputs=new Input[6];
        for(int i=0;i<6;i++) { inputs[i].type=1; inputs[i].data.keyboard.key=(ushort)keys[i]; inputs[i].data.keyboard.flags=(uint)((i>=3?2:0)|((keys[i]==91||keys[i]==37||keys[i]==39)?1:0)); }
        if(SendInput(6,inputs,Marshal.SizeOf(typeof(Input)))!=6) {
            // Best effort release of just our injected keys; never kill another process.
            SendInput(3,new Input[]{inputs[3],inputs[4],inputs[5]},Marshal.SizeOf(typeof(Input)));
            throw new Exception("Windows 未接受桌面快捷键。请切回普通权限窗口后重试。");
        }
    }
}
sealed class Snapshot {
    public Guid[] Ids; public Guid Current;
    public int Index { get { return Array.IndexOf(Ids,Current); } }
    public static Guid GuidAt(byte[] b,int offset) { var x=new byte[16]; Array.Copy(b,offset,x,0,16); return new Guid(x); }
    public static Snapshot Read() {
        const string path=@"Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops";
        using(var k=Registry.CurrentUser.OpenSubKey(path)) {
            if(k==null) throw new Exception("无法读取虚拟桌面状态。");
            var ids=k.GetValue("VirtualDesktopIDs") as byte[];
            var cur=k.GetValue("CurrentVirtualDesktop") as byte[];
            using(var session=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\SessionInfo\"+Process.GetCurrentProcess().SessionId+@"\VirtualDesktops")) {
                if(session!=null) { var sc=session.GetValue("CurrentVirtualDesktop") as byte[]; if(sc!=null && sc.Length==16) cur=sc; }
            }
            if(ids==null||ids.Length==0||ids.Length%16!=0||cur==null||cur.Length!=16) throw new Exception("系统未提供有效的桌面状态；已停止接管按键。");
            var s=new Snapshot{Ids=new Guid[ids.Length/16],Current=new Guid(cur)};
            for(int i=0;i<s.Ids.Length;i++) s.Ids[i]=GuidAt(ids,i*16);
            if(s.Index<0) throw new Exception("当前桌面不在桌面列表中；请稍后重新启用。");
            return s;
        }
    }
}
sealed class Binding {
    public int Key=9;
    public static bool ValidKey(int k) { return k==8||k==9||k==13||k==20||k==27||(k>=32&&k<=40)||k==45||k==46||(k>=48&&k<=57)||(k>=65&&k<=90)||(k>=96&&k<=135)||(k>=186&&k<=192)||(k>=219&&k<=222)||k==226; }
    public override string ToString() {
        if(Key==20) return "Caps Lock";
        if(Key>=48&&Key<=57) return ((char)Key).ToString();
        return ((Keys)Key).ToString();
    }
    public static Binding Load() {
        if(!File.Exists(Program.Config)) return new Binding();
        int k;
        if(!int.TryParse(File.ReadAllText(Program.Config).Trim(),out k)||!ValidKey(k)) throw new Exception("快捷键配置无效。删除 "+Program.Config+" 后重试。");
        return new Binding{Key=k};
    }
    public void Save() {
        Directory.CreateDirectory(Program.Root); string tmp=Program.Config+".tmp";
        File.WriteAllText(tmp,Key.ToString());
        if(File.Exists(Program.Config)) File.Replace(tmp,Program.Config,null); else File.Move(tmp,Program.Config);
    }
}
// Tracks ownership for the entire key press, including repeats and modifier changes.
sealed class KeyGate {
    bool held,owned;
    public bool Process(bool down, bool match, bool enabled, out bool trigger) {
        trigger=false;
        if(down) { if(!held) { held=true; owned=match&&enabled; trigger=owned; } return owned; }
        bool result=owned; held=false; owned=false; return result;
    }
}
sealed class Engine : IDisposable {
    readonly AutoResetEvent trigger=new AutoResetEvent(false);
    readonly ManualResetEvent cancel=new ManualResetEvent(false);
    readonly Thread worker;
    readonly Action<string> failed;
    Native.HookProc proc; IntPtr hook;
    KeyGate gate=new KeyGate();
    public volatile bool Ready,Paused;
    public volatile Binding Binding;
    int busy=1; bool disposed;
    public void Rebind(Binding value) {
        Binding=value; gate=new KeyGate();
        // A key already held while saving belongs to the foreground application.
        if(Native.Down(value.Key)) { bool ignored; gate.Process(true,false,false,out ignored); }
    }
    public Engine(Binding binding,Action<string> onFailure) { Binding=binding; failed=onFailure; worker=new Thread(Loop){IsBackground=true,Name="Desktop switching"}; }
    public void Start() {
        proc=Callback; hook=Native.SetWindowsHookEx(13,proc,Native.GetModuleHandle(null),0);
        if(hook==IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        worker.Start();
    }
    IntPtr Callback(int code,IntPtr msg,IntPtr ptr) {
        if(code>=0) {
            var k=(Native.KeyData)Marshal.PtrToStructure(ptr,typeof(Native.KeyData)); var b=Binding;
            int m=msg.ToInt32(); bool down=m==256||m==260, up=m==257||m==261;
            // Synthetic input, including our own desktop chord, is never intercepted.
            if((k.flags&16)==0 && k.key==b.Key && (down||up)) {
                bool fire; bool eat=gate.Process(down,Native.Modifiers()==0,Ready&&!Paused,out fire);
                if(fire && Interlocked.CompareExchange(ref busy,1,0)==0) trigger.Set();
                if(eat) return (IntPtr)1;
            }
        }
        return Native.CallNextHookEx(hook,code,msg,ptr);
    }
    void WaitReleased() {
        var sw=Stopwatch.StartNew();
        while(Native.Modifiers()!=0||Native.Down(Binding.Key)) {
            if(cancel.WaitOne(20)) throw new OperationCanceledException();
            if(sw.ElapsedMilliseconds>4000) throw new Exception("快捷键按住超过 4 秒，已停止接管。请松开按键后重新启用。");
        }
    }
    void Send(int key) { WaitReleased(); if(cancel.WaitOne(0)) throw new OperationCanceledException(); Native.ShellKey(key); }
    Snapshot WaitChange(Guid old,int count,bool creating) {
        var sw=Stopwatch.StartNew();
        while(sw.ElapsedMilliseconds<2200) {
            if(cancel.WaitOne(40)) throw new OperationCanceledException();
            var s=Snapshot.Read();
            if(creating?s.Ids.Length>count:s.Current!=old) {
                // Give the shell animation time to settle before a subsequent step.
                if(cancel.WaitOne(280)) throw new OperationCanceledException();
                return Snapshot.Read();
            }
        }
        throw new Exception("未确认桌面切换成功，已停止接管按键。请在普通窗口中重新启用。");
    }
    public Snapshot EnsureTwo() {
        var s=Snapshot.Read();
        if(s.Ids.Length==1) { Send(68); s=WaitChange(s.Current,1,true); }
        return s;
    }
    public void Go(Guid target) {
        var total=Stopwatch.StartNew();
        for(int step=0;step<64;step++) {
            var s=Snapshot.Read(); int to=Array.IndexOf(s.Ids,target);
            if(to<0) throw new Exception("目标桌面已被删除，已停止接管。");
            if(s.Current==target) return;
            if(total.ElapsedMilliseconds>15000) throw new Exception("桌面切换超时。");
            Send(to>s.Index?39:37); WaitChange(s.Current,s.Ids.Length,false);
        }
        throw new Exception("桌面数量超出单次切换上限。");
    }
    public void ToggleDesktop() { var s=EnsureTwo(); Go(s.Ids[s.Index==0?1:0]); }
    void Loop() {
        try {
            EnsureTwo(); Ready=true; Interlocked.Exchange(ref busy,0);
            var waits=new WaitHandle[]{cancel,trigger};
            while(true) {
                int index=WaitHandle.WaitAny(waits,1000);
                if(index==0) return;
                if(index==1) { ToggleDesktop(); Interlocked.Exchange(ref busy,0); }
                else Snapshot.Read(); // Fail open if Explorer state disappears.
            }
        } catch(OperationCanceledException) {} catch(Exception ex) { Ready=false; failed(ex.Message); }
    }
    public void Dispose() {
        if(disposed) return; disposed=true; Ready=false; cancel.Set();
        if(hook!=IntPtr.Zero) { Native.UnhookWindowsHookEx(hook); hook=IntPtr.Zero; }
        if(worker.IsAlive) worker.Join(3000);
        // Worker uses bounded waits. Keep handles alive if shutdown raced a slow OS call.
        if(!worker.IsAlive) { cancel.Dispose(); trigger.Dispose(); }
        GC.KeepAlive(proc);
    }
}
sealed class KeyCapture : TextBox {
    public Binding Value;
    public KeyCapture(Binding value) {
        Value=new Binding{Key=value.Key}; ReadOnly=true; Text=Value.ToString();
        TextAlign=HorizontalAlignment.Center; ShortcutsEnabled=false;
    }
    public void Record(Keys data) {
        int k=(int)(data & Keys.KeyCode);
        if((data & Keys.Modifiers)!=Keys.None || Native.Modifiers()!=0 || !Binding.ValidKey(k)) return;
        Value=new Binding{Key=k}; Text=Value.ToString(); SelectAll();
    }
    protected override bool IsInputKey(Keys data) { return true; }
    protected override bool ProcessCmdKey(ref Message msg,Keys data) { Record(data); return true; }
    protected override void OnKeyDown(KeyEventArgs e) { Record(e.KeyData); e.Handled=true; e.SuppressKeyPress=true; }
    protected override void OnEnter(EventArgs e) { base.OnEnter(e); SelectAll(); }
}
sealed class TrayApp : ApplicationContext, IMessageFilter {
    readonly NotifyIcon tray; readonly Engine engine; readonly System.Windows.Forms.Timer timer;
    readonly Icon trayIcon;
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr handle);
    static Icon MakeTrayIcon() {
        using(var bitmap=new Bitmap(32,32)) using(var g=Graphics.FromImage(bitmap)) {
            g.Clear(Color.Transparent);
            using(var pen=new Pen(Color.FromArgb(135,143,155),3)) {
                g.DrawRectangle(pen,5,6,17,15);
                g.DrawLine(pen,10,25,26,25);
                g.DrawLine(pen,26,10,26,25);
            }
            IntPtr handle=bitmap.GetHicon();
            try { using(var temp=Icon.FromHandle(handle)) return (Icon)temp.Clone(); }
            finally { DestroyIcon(handle); }
        }
    }
    readonly EventWaitHandle stop; string failure; bool announced, cleaned, editing;
    Form status; Label statusText, feedback; KeyCapture capture; Button change, hide;
    static readonly Color Ink=Color.FromArgb(28,37,54), Muted=Color.FromArgb(105,116,135), Blue=Color.FromArgb(64,94,232);
    static Label LabelAt(string text,int x,int y,int width,int height,float size,Color color) {
        return new Label{Text=text,Left=x,Top=y,Width=width,Height=height,ForeColor=color,Font=new Font("Microsoft YaHei UI",size,FontStyle.Regular),BackColor=Color.Transparent};
    }
    static Button ButtonAt(string text,int x,int width,Color fill,Color ink) {
        var b=new Button{Text=text,Left=x,Top=164,Width=width,Height=36,BackColor=fill,ForeColor=ink,FlatStyle=FlatStyle.Flat,Cursor=Cursors.Hand,Font=new Font("Microsoft YaHei UI",10),UseVisualStyleBackColor=false};
        b.FlatAppearance.BorderSize=0; return b;
    }
    public TrayApp(EventWaitHandle stopEvent) {
        stop=stopEvent;
        engine=new Engine(Binding.Load(),delegate(string text){ Interlocked.Exchange(ref failure,text); });
        trayIcon=MakeTrayIcon();
        tray=new NotifyIcon{Icon=trayIcon,Text="桌面工具",Visible=true};
        var menu=new ContextMenuStrip(); menu.Items.Add("打开主窗口",null,delegate { ShowStatus(); });
        menu.Items.Add("更改按键…",null,delegate { ShowSettings(); });
        menu.Items.Add("关闭并恢复按键",null,delegate { ExitThread(); }); tray.ContextMenuStrip=menu;
        tray.DoubleClick+=delegate { ShowStatus(); };
        timer=new System.Windows.Forms.Timer{Interval=100}; timer.Tick+=Tick;
        try { engine.Start(); timer.Start(); Application.AddMessageFilter(this); } catch { engine.Dispose(); tray.Dispose(); timer.Dispose(); throw; }
    }
    public bool PreFilterMessage(ref Message msg) {
        // Capture before WinForms treats Tab/Enter/Escape/arrows as navigation.
        // Scope strictly to this foreground form while explicitly recording.
        if(!editing || status==null || status.IsDisposed || !status.ContainsFocus) return false;
        if(msg.Msg==0x100 || msg.Msg==0x104) {
            int key=msg.WParam.ToInt32();
            if(Native.Modifiers()==0 && Binding.ValidKey(key)) {
                capture.Record((Keys)key);
                return true;
            }
        }
        return false;
    }
    void ShowSettings() {
        if(cleaned) return; ShowStatus();
        if(editing) { capture.Focus(); return; }
        editing=true; engine.Paused=true;
        capture.Value=new Binding{Key=engine.Binding.Key}; capture.Text=capture.Value.ToString();
        statusText.Visible=false; capture.Visible=true;
        feedback.Text="请直接按一下新键，然后点击保存。";
        feedback.ForeColor=Blue; change.Text="保存按键"; hide.Text="取消更改";
        capture.Focus(); capture.SelectAll();
    }
    void EndEditing(string message) {
        editing=false; engine.Paused=false;
        if(status==null || status.IsDisposed) return;
        capture.Visible=false; statusText.Text=engine.Binding.ToString(); statusText.Visible=true;
        change.Text="更改按键"; hide.Text="隐藏窗口";
        feedback.Text=message; feedback.ForeColor=Color.FromArgb(27,132,100);
        tray.Text="桌面工具";
    }
    void SaveBinding() {
        try {
            var value=capture.Value; value.Save(); engine.Rebind(value);
            EndEditing("已保存 · 新按键已生效"); status.Show(); status.Activate(); change.Focus();
        } catch(Exception ex) { MessageBox.Show(status,ex.Message,"保存失败",MessageBoxButtons.OK,MessageBoxIcon.Error); }
    }
    void ShowStatus() {
        if(cleaned) return;
        if(status!=null && !status.IsDisposed) { status.Show(); status.Activate(); return; }
        status=new Form{Text="桌面切换",ClientSize=new Size(400,244),FormBorderStyle=FormBorderStyle.FixedSingle,MaximizeBox=false,MinimizeBox=false,StartPosition=FormStartPosition.CenterScreen,BackColor=Color.White,Font=new Font("Microsoft YaHei UI",10),AutoScaleMode=AutoScaleMode.Dpi};
        var caption=LabelAt("当前按键",24,21,220,24,10,Muted);
        var badge=LabelAt("● 已开启",294,21,90,24,9,Color.FromArgb(27,132,100));
        statusText=LabelAt(engine.Binding.ToString(),24,53,352,55,28,Ink); statusText.TextAlign=ContentAlignment.MiddleCenter;
        capture=new KeyCapture(engine.Binding){Left=24,Top=55,Width=352,Font=new Font("Microsoft YaHei UI",23),BorderStyle=BorderStyle.FixedSingle,BackColor=Color.FromArgb(247,249,252),ForeColor=Ink,Visible=false};
        feedback=LabelAt("桌面 1  ↔  桌面 2",24,118,352,24,9,Muted); feedback.TextAlign=ContentAlignment.MiddleCenter;
        change=ButtonAt("更改按键",24,124,Blue,Color.White);
        hide=ButtonAt("隐藏",160,102,Color.FromArgb(242,244,248),Ink);
        var quit=ButtonAt("关闭工具",274,102,Color.FromArgb(242,244,248),Ink);
        change.Click+=delegate { if(editing) SaveBinding(); else ShowSettings(); };
        hide.Click+=delegate { if(editing) EndEditing("已取消 · 原按键保持不变"); else status.Close(); };
        quit.Click+=delegate { ExitThread(); };
        var note=LabelAt("隐藏后继续运行，关闭工具后恢复原按键。",24,213,352,20,8,Muted); note.TextAlign=ContentAlignment.MiddleCenter;
        status.Controls.AddRange(new Control[]{caption,badge,statusText,capture,feedback,change,hide,quit,note});
        status.FormClosed+=delegate { editing=false; engine.Paused=false; };
        status.Show(); status.Activate();
    }
    void Tick(object sender,EventArgs e) {
        if(stop.WaitOne(0)) { ExitThread(); return; }
        string error=Interlocked.Exchange(ref failure,null);
        if(error!=null) { Program.Log(error); ExitThread(); MessageBox.Show(error,"桌面切换已关闭",MessageBoxButtons.OK,MessageBoxIcon.Warning); return; }
        if(engine.Ready&&!announced) { announced=true; tray.Text="桌面工具"; ShowStatus(); }
    }
    void Cleanup() {
        if(cleaned) return; cleaned=true; Application.RemoveMessageFilter(this); timer.Stop(); engine.Dispose(); if(status!=null) status.Dispose(); tray.Visible=false; tray.Dispose(); trayIcon.Dispose(); timer.Dispose();
    }
    protected override void Dispose(bool disposing) { if(disposing) Cleanup(); base.Dispose(disposing); }
    protected override void ExitThreadCore() { Cleanup(); base.ExitThreadCore(); }
}

static class Program {
    public static readonly string Root=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"DesktopToggle");
    public static readonly string Config=Path.Combine(Root,"hotkey.txt");
    public static void Log(string s) { try { Directory.CreateDirectory(Root); File.WriteAllText(Path.Combine(Root,"last-error.txt"),DateTime.Now.ToString("s")+" "+s); } catch {} }
    [STAThread] static int Main(string[] args) {
        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        if(args.Length>0 && args[0]=="--verify") return Verify(args.Length>1?args[1]:"verification.txt");
        string id=@"Local\DesktopToggle_v1_"+WindowsIdentity.GetCurrent().User.Value;
        using(var mutex=new Mutex(false,id)) {
            bool owner=false;
            try {
                try { owner=mutex.WaitOne(0); } catch(AbandonedMutexException) { owner=true; }
                if(!owner) {
                    for(int i=0;i<30;i++) { try { using(var ev=EventWaitHandle.OpenExisting(id+"_stop")) ev.Set(); return 0; } catch(WaitHandleCannotBeOpenedException) { Thread.Sleep(100); } }
                    throw new Exception("正在启动或关闭，请稍后重试。");
                }
                using(var stop=new EventWaitHandle(false,EventResetMode.ManualReset,id+"_stop")) {
                    Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException);
                    using(var app=new TrayApp(stop)) Application.Run(app);
                }
                return 0;
            } catch(Exception ex) { Log(ex.ToString()); MessageBox.Show(ex.Message,"桌面切换未启用",MessageBoxButtons.OK,MessageBoxIcon.Error); return 1; }
            finally { if(owner) mutex.ReleaseMutex(); }
        }
    }
    static void Check(bool b,string message) { if(!b) throw new Exception("FAIL: "+message); }
    static int Verify(string path) {
        var report=new System.Text.StringBuilder(); Guid original=Guid.Empty;
        using(var engine=new Engine(new Binding(),delegate{})) {
            try {
                Check(Marshal.SizeOf(typeof(Native.Input))==40,"x64 INPUT layout");
                bool fire; var g=new KeyGate();
                Check(g.Process(true,true,true,out fire)&&fire,"trigger down");
                Check(g.Process(true,false,true,out fire)&&!fire,"repeat/modifier transition");
                Check(g.Process(false,false,true,out fire),"paired release");
                Check(!g.Process(true,false,true,out fire),"modified Tab pass-through");
                Check(!g.Process(true,true,true,out fire),"do not steal held pass-through key");
                Check(!g.Process(false,true,true,out fire),"pass-through release");
                Check(!g.Process(true,true,false,out fire),"paused pass-through");
                g.Process(false,true,false,out fire);
                report.AppendLine("PASS: key ownership, repeat, modifier transition, pause; INPUT x64 layout.");
                var s=Snapshot.Read(); original=s.Current; report.AppendLine("Initial desktops="+s.Ids.Length+", index="+s.Index);
                var ready=engine.EnsureTwo(); Check(ready.Ids.Length>=2,"auto create second desktop"); report.AppendLine("PASS: at least two desktops (created only if initially one).");
                engine.Go(ready.Ids[0]); engine.ToggleDesktop(); Check(Snapshot.Read().Index==1,"1 -> 2");
                engine.ToggleDesktop(); Check(Snapshot.Read().Index==0,"2 -> 1");
                engine.Go(ready.Ids[1]); engine.ToggleDesktop(); Check(Snapshot.Read().Index==0,"actual state resync");
                report.AppendLine("PASS: real shell switching 1->2->1 and external-state resync, confirmed by registry GUIDs.");
                engine.Go(original); report.AppendLine("PASS: original desktop restored.");
                File.WriteAllText(path,report.ToString()); return 0;
            } catch(Exception ex) {
                report.AppendLine(ex.ToString());
                if(original!=Guid.Empty) try { engine.Go(original); report.AppendLine("Original desktop restored after failure."); } catch(Exception restore) { report.AppendLine("Restore failed: "+restore.Message); }
                File.WriteAllText(path,report.ToString()); return 1;
            }
        }
    }
}
}



