// Single-file launcher for the Windows build of 听歌小窝.
//
// Source stays pure ASCII on purpose: csc.exe (the .NET Framework compiler that ships
// with Windows) reads a BOM-less file with the machine's ANSI code page, and UTF-8
// Chinese decoded through cp936 can emit stray quote/asterisk bytes -- enough to break
// a comment. Every Chinese literal below is therefore spelled with \u escapes, the same
// trick windows-portable.yml uses for the runner's window title.
//
// What it does: the launcher exe has the ordinary portable zip appended to it, so the
// deliverable is one file. On first run it unpacks that payload into
// %LOCALAPPDATA%\听歌小窝 and starts the real exe from there; later runs only unpack
// again when the embedded version differs from the stamp file, which keeps the
// double-click instant. Her data (settings / favorites / logs / covers) lives in
// `data\` next to that exe, i.e. inside the same folder, and is not part of the payload
// -- so a version update rewrites program files without touching what she accumulated.
//
// Build (see .github/workflows/windows-portable.yml, step "单文件版"). The switches are
// spelled with a leading dash, not a slash: this gets invoked from Git Bash on some
// machines, and bash rewrites "/nologo" into a path before csc ever sees it.
//   csc -nologo -target:winexe -win32icon:app.ico
//       -r:System.IO.Compression.dll -r:System.IO.Compression.FileSystem.dll
//       -r:System.Drawing.dll -out:launcher.exe launcher.cs
//   <launcher exe bytes> + <songbox-<ver>-windows-x64-portable.zip>  ->  one .exe
//
// Test switches (not used when she double-clicks):
//   /dir:<path>  unpack somewhere else instead of %LOCALAPPDATA%
//   /check       unpack, then stop; no window, no app launch
//   /log:<path>  write what happened to that file (a winexe has no console to talk to)

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Windows.Forms;

// What Explorer and 属性→详细信息 show for this file. Without them the deliverable is a
// nameless 20MB blob: hover says nothing, the version tab says 0.0.0.0, and task manager
// has no description to put next to the process. AssemblyVersion is not a version we
// bind against (nothing references this assembly), so reusing Version is safe.
[assembly: System.Reflection.AssemblyTitle(Launcher.AppName)]
[assembly: System.Reflection.AssemblyProduct(Launcher.AppName)]
[assembly: System.Reflection.AssemblyDescription(Launcher.AppName)]
[assembly: System.Reflection.AssemblyVersion(Launcher.Version)]
[assembly: System.Reflection.AssemblyFileVersion(Launcher.Version)]

static class Launcher
{
    const string AppExe = "lyric_music.exe";
    const string StampFile = "songbox-version.txt";

    // 听歌小窝
    public const string AppName = "\u542c\u6b4c\u5c0f\u7a9d";

    // 正在准备程序文件
    const string Preparing = "\u6b63\u5728\u51c6\u5907\u7a0b\u5e8f\u6587\u4ef6";

    // Built by the workflow: the version line of pubspec.yaml is patched into this
    // literal before compiling, so the payload and the stamp can never disagree. Public
    // because the assembly attributes above read it; the workflow patches the text after
    // "const string Version", which still matches with the modifier in front.
    public const string Version = "0.8.37";

    static string _status = "idle";
    static string _logPath = null;

    [STAThread]
    static int Main(string[] args)
    {
        string target = DefaultTarget();
        bool checkOnly = false;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i].StartsWith("/dir:")) target = args[i].Substring(5).Trim('"');
            else if (args[i].StartsWith("/log:")) _logPath = args[i].Substring(5).Trim('"');
            else if (args[i] == "/check") checkOnly = true;
        }
        Log("start version=" + Version + " target=" + target + " check=" + checkOnly);

        string exe = Path.Combine(target, AppExe);
        if (IsCurrent(target, exe))
        {
            Log("stamp matches, no unpack");
            if (!checkOnly) ActivateOrStart(target, exe);
            return 0;
        }

        if (RunningInstance(target) != null)
        {
            // already unpacked and playing: half-overwriting the files under it is how a
            // running app ends up mixing two versions, so say so instead
            _status = AppName + " \u5df2\u7ecf\u5728\u653e\u4e86\uff0c\u5148\u628a\u5b83\u5173\u6389\u518d\u70b9\u4e00\u6b21\u3002";
            Log("busy: " + _status);
            if (!checkOnly) Notify(_status);
            return 3;
        }

        if (checkOnly)
        {
            int code = ExtractSelf(target);
            Log("check done code=" + code + " " + _status);
            return code;
        }
        return WithProgress(target, exe);
    }

    static string DefaultTarget()
    {
        string root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrEmpty(root))
            root = Path.GetDirectoryName(Application.ExecutablePath);
        return Path.Combine(root, AppName);
    }

    static bool IsCurrent(string target, string exe)
    {
        try
        {
            if (!File.Exists(exe)) return false;
            string stamp = Path.Combine(target, StampFile);
            if (!File.Exists(stamp)) return false;
            return File.ReadAllText(stamp).Trim() == Version;
        }
        catch { return false; }
    }

    // The real exe of an instance unpacked in this folder, or null. MainModule.FileName
    // throws for access-denied cases; those are not ours, so skip them.
    static Process RunningInstance(string target)
    {
        string full = Path.GetFullPath(target).TrimEnd('\\') + "\\";
        Process[] list = Process.GetProcessesByName(Path.GetFileNameWithoutExtension(AppExe));
        for (int i = 0; i < list.Length; i++)
        {
            try
            {
                string path = list[i].MainModule.FileName;
                if (path.StartsWith(full, StringComparison.OrdinalIgnoreCase)) return list[i];
            }
            catch { }
        }
        return null;
    }

    static void ActivateOrStart(string target, string exe)
    {
        Process live = RunningInstance(target);
        if (live == null) { Start(target, exe); return; }
        try
        {
            // double-clicking the icon while it is already open should bring it forward,
            // not stack a second window (SW_RESTORE covers the minimized case)
            if (live.MainWindowHandle != IntPtr.Zero)
            {
                ShowWindow(live.MainWindowHandle, 9);
                SetForegroundWindow(live.MainWindowHandle);
            }
        }
        catch { }
    }

    static void Start(string target, string exe)
    {
        ProcessStartInfo psi = new ProcessStartInfo(exe);
        psi.WorkingDirectory = target;
        psi.UseShellExecute = true;
        try { Process.Start(psi); Log("launched " + exe); }
        catch (Exception e) { Notify(exe + "\n" + e.Message); }
    }

    // Unpack the payload appended to this very exe, behind a small always-on-top label:
    // 20.6 MB compressed expands to 47.2 MB across 38 entries, which takes a second or
    // two, and a double-click that shows nothing looks like a broken icon.
    static int WithProgress(string target, string exe)
    {
        Form[] holder = new Form[1];
        Label[] label = new Label[1];
        int code = 0;
        System.Threading.Thread worker = new System.Threading.Thread(delegate()
        {
            code = ExtractSelf(target);
            try { holder[0].BeginInvoke((MethodInvoker)delegate { holder[0].Close(); }); } catch { }
            if (code == 0) Start(target, exe);
            else Notify(_status);
        });
        worker.IsBackground = true;

        Form f = new Form();
        holder[0] = f;
        f.Text = AppName;
        f.FormBorderStyle = FormBorderStyle.None;
        f.StartPosition = FormStartPosition.CenterScreen;
        f.Size = new Size(430, 92);
        f.TopMost = true;
        f.ShowInTaskbar = true;
        f.BackColor = Color.FromArgb(24, 26, 32);
        Label l = new Label();
        label[0] = l;
        l.Dock = DockStyle.Fill;
        l.TextAlign = ContentAlignment.MiddleCenter;
        l.ForeColor = Color.FromArgb(232, 232, 236);
        l.Text = AppName + " " + Preparing + "\u2026";
        f.Controls.Add(l);

        Timer t = new Timer();
        t.Interval = 200;
        t.Tick += delegate
        {
            string s = _status;
            if (s.StartsWith("EXTRACTED "))
            {
                string[] parts = s.Split(' ');
                l.Text = AppName + " " + Preparing + " " + parts[1];
            }
        };
        t.Start();
        f.Shown += delegate { if (!worker.IsAlive) worker.Start(); };
        Application.EnableVisualStyles();
        Application.Run(f);
        t.Stop();
        Log("progress window closed code=" + code + " " + _status);
        return code;
    }

    static int ExtractSelf(string target)
    {
        string self = Application.ExecutablePath;
        string temp = Path.Combine(Path.GetTempPath(), "songbox-payload-" + Version + "-" +
            Process.GetCurrentProcess().Id + ".zip");
        try
        {
            if (!SlicePayload(self, temp))
            {
                _status = "NO PAYLOAD";
                return 4;
            }
            Directory.CreateDirectory(target);
            string rootFull = Path.GetFullPath(target).TrimEnd('\\') + "\\";
            int count = 0;
            long done = 0, total = 0;
            using (ZipArchive zip = ZipFile.Open(temp, ZipArchiveMode.Read))
            {
                count = zip.Entries.Count;
                for (int i = 0; i < count; i++) total += zip.Entries[i].Length;
                for (int i = 0; i < count; i++)
                {
                    ZipArchiveEntry en = zip.Entries[i];
                    string rel = en.FullName.Replace('/', Path.DirectorySeparatorChar);
                    string dest = Path.GetFullPath(Path.Combine(rootFull, rel));
                    // never let an entry climb out of the folder
                    if (!dest.StartsWith(rootFull, StringComparison.OrdinalIgnoreCase)) continue;
                    if (en.FullName.EndsWith("/"))
                    {
                        Directory.CreateDirectory(dest);
                    }
                    else
                    {
                        Directory.CreateDirectory(Path.GetDirectoryName(dest));
                        CopyOut(en, dest);
                        done += en.Length;
                    }
                    _status = "EXTRACTED " + (i + 1) + "/" + count + " " + Percent(done, total);
                }
            }
            File.WriteAllText(Path.Combine(target, StampFile), Version);
            _status = "OK unpacked=" + count + " into " + target;
            return 0;
        }
        catch (Exception e)
        {
            _status = "FAIL " + e.GetType().Name + ": " + e.Message;
            return 5;
        }
        finally
        {
            try { if (File.Exists(temp)) File.Delete(temp); } catch { }
        }
    }

    // Write to .new then swap: a half-written dll is how an interrupted update turns the
    // whole package into something that will not start.
    static void CopyOut(ZipArchiveEntry entry, string dest)
    {
        string tmp = dest + ".new";
        using (Stream src = entry.Open())
        using (Stream dst = File.Create(tmp))
        {
            src.CopyTo(dst, 1 << 20);
        }
        if (File.Exists(dest)) File.Delete(dest);
        File.Move(tmp, dest);
    }

    static string Percent(long done, long total)
    {
        if (total <= 0) return "?";
        return (done * 100 / total) + "%";
    }

    // The appended zip is a self-contained blob, so its central-directory offsets are
    // relative to where the blob starts, not to the start of this exe -- which is why
    // ZipFile.OpenRead on the exe itself reports 0 entries. Read the end-of-central-
    // directory record, then: blobStart = (absEocd - cdSize) - cdOffset.
    static bool SlicePayload(string self, string outPath)
    {
        long size = new FileInfo(self).Length;
        int tail = (int)Math.Min(65536, size);
        byte[] buf = new byte[tail];
        using (FileStream fs = File.OpenRead(self))
        {
            fs.Seek(size - tail, SeekOrigin.Begin);
            fs.Read(buf, 0, tail);
            int eocd = -1;
            for (int i = tail - 22; i >= 0; i--)
            {
                if (buf[i] == 0x50 && buf[i + 1] == 0x4b && buf[i + 2] == 0x05 && buf[i + 3] == 0x06)
                {
                    eocd = i;
                    break;
                }
            }
            if (eocd < 0) return false;
            long cdSize = ToU32(buf, eocd + 12);
            long cdOffset = ToU32(buf, eocd + 16);
            long blobStart = (size - tail) + eocd - cdSize - cdOffset;
            if (blobStart < 0 || blobStart >= size) return false;
            // The number below is where the EOCD sits inside the tail buffer, not the
            // launcher length -- the two only coincide when the zip carries no comment,
            // so don't label it anything that suggests otherwise.
            Log("blobStart=" + blobStart + " eocdAt=" + eocd + " tail=" + tail);
            fs.Seek(blobStart, SeekOrigin.Begin);
            using (FileStream os = File.Create(outPath))
            {
                fs.CopyTo(os, 1 << 20);
            }
            return true;
        }
    }

    static long ToU32(byte[] b, int at)
    {
        return (long)b[at] | ((long)b[at + 1] << 8) | ((long)b[at + 2] << 16) | ((long)b[at + 3] << 24);
    }

    static void Notify(string text)
    {
        MessageBox.Show(text, AppName, MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    static void Log(string line)
    {
        if (_logPath == null) return;
        try
        {
            File.AppendAllText(_logPath, DateTime.Now.ToString("HH:mm:ss") + " " + line + Environment.NewLine);
        }
        catch { }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern bool SetForegroundWindow(IntPtr hWnd);
}
