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
        string suffix = Suffix(args);
        string dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".claude", "hooks", "claude-notify"
        );

        // Try process tree first (reliable for automated launches like DevLayout)
        IntPtr hwnd = FindWtWindowByProcessTree();

        // Fall back to foreground window (works for manual setup in focused tab)
        if (hwnd == IntPtr.Zero)
        {
            hwnd = GetForegroundWindow();
            if (hwnd == IntPtr.Zero) return;

            // Verify it's a WindowsTerminal window
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            try
            {
                var proc = Process.GetProcessById((int)pid);
                if (proc.ProcessName != "WindowsTerminal") return;
            }
            catch { return; }
        }

        // Save HWND
        File.WriteAllText(Path.Combine(dir, ".hwnd" + suffix), hwnd.ToInt64().ToString());

        // Find and save the currently selected tab's index (1-based)
        try
        {
            File.WriteAllText(Path.Combine(dir, ".savehwnd-debug" + suffix), "starting tab enum");

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
                        File.WriteAllText(Path.Combine(dir, ".tabindex" + suffix), idx.ToString());
                        // Also save name for display
                        string name = tab.Current.Name ?? "";
                        string clean = Regex.Replace(name, @"[^\x20-\x7E]", "").Trim();
                        File.WriteAllText(Path.Combine(dir, ".tabname" + suffix), clean);
                        break;
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
