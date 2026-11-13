using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Automation;

class SaveHwnd
{
    [DllImport("user32.dll")]
    static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    static extern int GetWindowTextLength(IntPtr hWnd);

    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    static int GetParentPid(int pid)
    {
        try
        {
            using (var searcher = new ManagementObjectSearcher(
                "SELECT ParentProcessId FROM Win32_Process WHERE ProcessId = " + pid))
            {
                foreach (ManagementObject item in searcher.Get())
                {
                    return Convert.ToInt32(item["ParentProcessId"]);
                }
            }
        }
        catch { }
        return -1;
    }

    static IntPtr FindWindowByProcessId(int targetPid)
    {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            if (!IsWindowVisible(hWnd)) return true;
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if ((int)pid == targetPid)
            {
                int titleLen = GetWindowTextLength(hWnd);
                if (titleLen > 0)
                {
                    result = hWnd;
                    return false;
                }
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    static IntPtr FindWtWindowByProcessTree()
    {
        int pid = Process.GetCurrentProcess().Id;

        // Walk up parent processes looking for WindowsTerminal
        for (int i = 0; i < 20; i++)
        {
            pid = GetParentPid(pid);
            if (pid <= 0) break;

            try
            {
                var proc = Process.GetProcessById(pid);
                if (proc.ProcessName == "WindowsTerminal")
                {
                    // Find the visible window owned by this WT process
                    IntPtr hwnd = FindWindowByProcessId(pid);
                    if (hwnd != IntPtr.Zero) return hwnd;
                }
            }
            catch { }
        }
        return IntPtr.Zero;
    }

    // Optional argv[0] = session id. When given, state is written to
    // session-keyed filenames (.hwnd-<id> etc.) so concurrent tabs cannot race
    // on the shared unkeyed files. With no arg the original unkeyed behaviour
    // is preserved, which is what setup.sh expects.
    static string Suffix(string[] args)
    {
        if (args == null || args.Length == 0) return "";
        string s = args[0];
        if (string.IsNullOrEmpty(s)) return "";
        s = Regex.Replace(s, @"[^A-Za-z0-9_-]", "");
        return s.Length == 0 ? "" : "-" + s;
    }

    static void Main(string[] args)
    {
        // Runs from notification hooks: an unhandled exception would only print
        // a crash dialog or stack trace, so swallow everything.
        try { Run(args); } catch { }
    }

    [DllImport("kernel32.dll")]
    static extern bool FreeConsole();

    [DllImport("kernel32.dll")]
    static extern bool AttachConsole(uint processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern bool SetConsoleTitle(string title);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern int GetConsoleTitle(StringBuilder title, int size);

    static string StateDir()
    {
        // Tests point the whole notifier at a scratch directory.
        string overridden = Environment.GetEnvironmentVariable("AGENTIC_NOTIFY_DIR");
        if (!string.IsNullOrEmpty(overridden)) return overridden;
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".claude", "hooks", "agentic-cli-notify"
        );
    }

    static List<IntPtr> TerminalWindows()
    {
        var windows = new List<IntPtr>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            if (IsWindowVisible(hWnd) && GetWindowTextLength(hWnd) > 0 && IsWindowsTerminal(hWnd)) windows.Add(hWnd);
            return true;
        }, IntPtr.Zero);
        return windows;
    }

    class Probe
    {
        public string Session;
        public uint ProcessId;
        public string Marker;
        public string OldTitle;
        public bool Found;
    }

    // save-hwnd.exe --locate <session>:<pid> [<session>:<pid> ...]
    //
    // Finds where each tab is right now, whichever tab is selected and whichever
    // window it was dragged to. Windows Terminal exposes no tab identity, so the
    // tab is made to identify itself: a process attached to its console gets a
    // marker as console title, the marker shows up as the tab's name, and the
    // old title is put back. <pid> is any process running in the tab.
    //
    // Nothing is written for a tab whose marker never shows (a tab the user
    // renamed, or suppressApplicationTitle): the files of the last capture stay.
    static void Locate(string[] args)
    {
        string dir = StateDir();
        var probes = new List<Probe>();
        for (int i = 1; i < args.Length; i++)
        {
            string[] parts = args[i].Split(':');
            uint pid;
            if (parts.Length != 2 || !uint.TryParse(parts[1], out pid)) continue;
            string session = Regex.Replace(parts[0], @"[^A-Za-z0-9_-]", "");
            if (session.Length == 0) continue;
            probes.Add(new Probe { Session = session, ProcessId = pid });
        }
        if (probes.Count == 0) return;

        FreeConsole();
        var active = new List<Probe>();
        foreach (Probe probe in probes)
        {
            if (!AttachConsole(probe.ProcessId)) continue;
            var title = new StringBuilder(2048);
            GetConsoleTitle(title, title.Capacity);
            probe.OldTitle = title.ToString();
            probe.Marker = "ntfy-" + Guid.NewGuid().ToString("N").Substring(0, 12);
            SetConsoleTitle(probe.Marker);
            FreeConsole();
            active.Add(probe);
        }

        try
        {
            var condition = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.TabItem);
            var watch = Stopwatch.StartNew();
            int missing = active.Count;
            while (missing > 0 && watch.ElapsedMilliseconds < 2000)
            {
                foreach (IntPtr window in TerminalWindows())
                {
                    try
                    {
                        var tabs = AutomationElement.FromHandle(window).FindAll(TreeScope.Descendants, condition);
                        for (int index = 0; index < tabs.Count; index++)
                        {
                            string name = tabs[index].Current.Name ?? "";
                            foreach (Probe probe in active)
                            {
                                if (probe.Found || name.IndexOf(probe.Marker, StringComparison.Ordinal) < 0) continue;
                                probe.Found = true;
                                missing--;
                                File.WriteAllText(Path.Combine(dir, ".hwnd-" + probe.Session), window.ToInt64().ToString());
                                File.WriteAllText(Path.Combine(dir, ".tabindex-" + probe.Session), (index + 1).ToString());
                                File.WriteAllText(Path.Combine(dir, ".tabname-" + probe.Session),
                                    Regex.Replace(probe.OldTitle, @"[^\x20-\x7E]", "").Trim());
                            }
                        }
                    }
                    catch { }
                }
                if (missing > 0) System.Threading.Thread.Sleep(40);
            }
        }
        finally
        {
            foreach (Probe probe in active)
            {
                if (!AttachConsole(probe.ProcessId)) continue;
                // The agent may have set a title of its own in the meantime: keep that one.
                var title = new StringBuilder(2048);
                GetConsoleTitle(title, title.Capacity);
                if (title.ToString().IndexOf(probe.Marker, StringComparison.Ordinal) >= 0) SetConsoleTitle(probe.OldTitle);
                FreeConsole();
            }
        }
    }

    static void Run(string[] args)
    {
        if (args != null && args.Length > 1 && args[0] == "--locate")
        {
            Locate(args);
            return;
        }

        string suffix = Suffix(args);
        string dir = StateDir();
        Directory.CreateDirectory(dir);

        // Read the foreground window before the slow parent-process walk: the user may
        // switch to another WT window a second after submitting a prompt.
        IntPtr hwnd = GetForegroundWindow();
        if (!IsWindowsTerminal(hwnd)) hwnd = IntPtr.Zero;

        int tabIndex = 0;
        string tabName = "";
        if (hwnd != IntPtr.Zero) ReadSelectedTab(hwnd, dir, suffix, out tabIndex, out tabName);

        // Fallback for automated launches (DevLayout) where WT is not yet in front.
        if (hwnd == IntPtr.Zero)
        {
            hwnd = FindWtWindowByProcessTree();
            if (hwnd == IntPtr.Zero) return;
            ReadSelectedTab(hwnd, dir, suffix, out tabIndex, out tabName);
        }

        File.WriteAllText(Path.Combine(dir, ".hwnd" + suffix), hwnd.ToInt64().ToString());
        if (tabIndex > 0)
        {
            File.WriteAllText(Path.Combine(dir, ".tabindex" + suffix), tabIndex.ToString());
            File.WriteAllText(Path.Combine(dir, ".tabname" + suffix), tabName);
        }
    }

    static bool IsWindowsTerminal(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return false;
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        try
        {
            return Process.GetProcessById((int)pid).ProcessName == "WindowsTerminal";
        }
        catch { return false; }
    }

    static void ReadSelectedTab(IntPtr hwnd, string dir, string suffix, out int tabIndex, out string tabName)
    {
        tabIndex = 0;
        tabName = "";
        try
        {
            var root = AutomationElement.FromHandle(hwnd);
            var tabs = root.FindAll(TreeScope.Descendants,
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.TabItem));

            int idx = 0;
            foreach (AutomationElement tab in tabs)
            {
                idx++;
                try
                {
                    var sel = (SelectionItemPattern)tab.GetCurrentPattern(SelectionItemPattern.Pattern);
                    if (sel.Current.IsSelected)
                    {
                        tabIndex = idx;
                        tabName = Regex.Replace(tab.Current.Name ?? "", @"[^\x20-\x7E]", "").Trim();
                        return;
                    }
                }
                catch { }
            }
        }
        catch (Exception ex)
        {
            File.WriteAllText(Path.Combine(dir, ".savehwnd-debug" + suffix), "ERROR: " + ex.ToString());
        }
    }
}
