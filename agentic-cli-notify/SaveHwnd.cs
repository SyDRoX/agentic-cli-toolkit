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

    static void Run(string[] args)
    {
        string suffix = Suffix(args);
        string dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".claude", "hooks", "agentic-cli-notify"
        );
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
