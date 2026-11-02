<#
  Qoder Meter for Windows - Win32 / SQLite interop
  仅使用 Windows 自带 DLL：user32 / dwmapi / winsqlite3
  C# 5 语法（PowerShell 5.1 Add-Type 的编译器限制），不使用插值与表达式成员。
#>

if (-not ('QoderMeter.Native' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace QoderMeter
{
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public static class Native
    {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool DestroyIcon(IntPtr hIcon);

        [DllImport("user32.dll")]
        public static extern bool GetCursorPos(out POINT point);

        public struct POINT { public int X; public int Y; }

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern uint GetDpiForWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
            int X, int Y, int cx, int cy, uint uFlags);

        [DllImport("user32.dll")]
        public static extern int GetWindowLongW(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll")]
        public static extern int SetWindowLongW(IntPtr hWnd, int nIndex, int dwNewLong);

        [DllImport("dwmapi.dll")]
        public static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out RECT pvAttribute, int cbAttribute);

        public static string GetTitle(IntPtr hWnd)
        {
            StringBuilder sb = new StringBuilder(1024);
            GetWindowTextW(hWnd, sb, sb.Capacity);
            return sb.ToString();
        }

        public static string GetClass(IntPtr hWnd)
        {
            StringBuilder sb = new StringBuilder(1024);
            GetClassNameW(hWnd, sb, sb.Capacity);
            return sb.ToString();
        }

        // DWMWA_EXTENDED_FRAME_BOUNDS = 9：去掉投影后的真实可视边界
        public static RECT DwmFrame(IntPtr hWnd)
        {
            RECT r;
            r.Left = 0; r.Top = 0; r.Right = 0; r.Bottom = 0;
            DwmGetWindowAttribute(hWnd, 9, out r, Marshal.SizeOf(typeof(RECT)));
            return r;
        }
    }

    public static class Sq
    {
        private const string DLL = "winsqlite3.dll";

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_open_v2(string filename, out IntPtr db, int flags, IntPtr vfs);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int nByte, out IntPtr stmt, IntPtr ppTail);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_step(IntPtr stmt);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_column_count(IntPtr stmt);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl, EntryPoint = "sqlite3_column_text")]
        public static extern IntPtr sqlite3_column_text_ptr(IntPtr stmt, int col);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_column_bytes(IntPtr stmt, int col);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        public static extern void sqlite3_finalize(IntPtr stmt);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_close_v2(IntPtr db);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        public static extern int sqlite3_busy_timeout(IntPtr db, int ms);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl, EntryPoint = "sqlite3_errmsg")]
        public static extern IntPtr sqlite3_errmsg_ptr(IntPtr db);

        private static string ErrMsg(IntPtr db)
        {
            IntPtr p = sqlite3_errmsg_ptr(db);
            if (p == IntPtr.Zero) { return "(no message)"; }
            return Marshal.PtrToStringAnsi(p);
        }

        public static IntPtr Open(string path)
        {
            IntPtr db;
            // SQLITE_OPEN_READONLY = 0x00000001, SQLITE_OPEN_URI = 0x00000040,
            // SQLITE_OPEN_SHAREDCACHE = 0x00020000
            int flags = 0x00000001 | 0x00000040 | 0x00020000;
            int rc = sqlite3_open_v2(path, out db, flags, IntPtr.Zero);
            if (rc != 0) { throw new Exception("sqlite3_open_v2 rc=" + rc + " path=" + path); }
            sqlite3_busy_timeout(db, 600);
            return db;
        }

        // 单行单列文本（用于 json_object 口径，一次拿到整段 JSON）
        public static string QueryText(IntPtr db, string sql)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(sql + "\0");
            IntPtr stmt;
            int rc = sqlite3_prepare_v2(db, bytes, bytes.Length, out stmt, IntPtr.Zero);
            if (rc != 0)
            {
                throw new Exception("prepare failed rc=" + rc + ": " + ErrMsg(db) + " | sql=" + sql.Substring(0, Math.Min(160, sql.Length)));
            }
            string result = null;
            try
            {
                int step = sqlite3_step(stmt);
                if (step == 100) // SQLITE_ROW
                {
                    result = ColumnText(stmt, 0);
                }
                else if (step != 101) // SQLITE_DONE
                {
                    throw new Exception("step rc=" + step + ": " + ErrMsg(db));
                }
            }
            finally
            {
                sqlite3_finalize(stmt);
            }
            return result;
        }

        public static string ColumnText(IntPtr stmt, int col)
        {
            int n = sqlite3_column_bytes(stmt, col);
            if (n <= 0) { return null; }
            IntPtr p = sqlite3_column_text_ptr(stmt, col);
            if (p == IntPtr.Zero) { return null; }
            byte[] buf = new byte[n];
            Marshal.Copy(p, buf, 0, n);
            return Encoding.UTF8.GetString(buf);
        }

        public static void Close(IntPtr db)
        {
            if (db != IntPtr.Zero) { sqlite3_close_v2(db); }
        }
    }
}
'@ -ErrorAction Stop
}
