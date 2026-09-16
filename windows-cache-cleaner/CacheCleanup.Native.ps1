#Requires -Version 5.1
# Handle-based deletion: hold every ancestor without FILE_SHARE_DELETE so
# another process cannot swap a directory for a junction after validation.
function Initialize-CacheNativeCode {
    if ('CDriveCleanup.NativeDelete' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CDriveCleanup {
    public sealed class DeleteResult {
        public bool Removed;
        public long Bytes;
        public string Reason;
    }
    public static class NativeDelete {
        const uint ReadAttributes = 0x80, DeleteAccess = 0x10000;
        const uint ShareReadWrite = 3, OpenExisting = 3;
        const uint OpenReparse = 0x00200000, BackupSemantics = 0x02000000;
        const uint ReparsePoint = 0x400, DirectoryAttribute = 0x10;
        [StructLayout(LayoutKind.Sequential)]
        struct FileTime { public uint Low; public uint High; }
        [StructLayout(LayoutKind.Sequential)]
        struct FileInfo {
            public uint Attributes;
            public FileTime Creation, Access, Write;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct Disposition { [MarshalAs(UnmanagedType.U1)] public bool DeleteFile; }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeFileHandle CreateFile(string path, uint access, uint share,
            IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInfo info);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool SetFileInformationByHandle(SafeFileHandle file, int infoClass,
            ref Disposition info, uint size);
        static long TimeValue(FileTime time) {
            return ((long)time.High << 32) | time.Low;
        }
        static FileInfo Inspect(SafeFileHandle handle) {
            FileInfo info;
            if (!GetFileInformationByHandle(handle, out info))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return info;
        }
        public static DeleteResult Delete(string path, string root, long cutoffFileTime) {
            var handles = new List<SafeFileHandle>();
            var result = new DeleteResult { Reason = "Unchanged" };
            try {
                if (String.IsNullOrWhiteSpace(path) || String.IsNullOrWhiteSpace(root) ||
                    !path.StartsWith(@"C:\", StringComparison.OrdinalIgnoreCase) ||
                    !root.StartsWith(@"C:\", StringComparison.OrdinalIgnoreCase) ||
                    path.IndexOf('/') >= 0 || path.IndexOf(':', 2) >= 0)
                    throw new IOException("Only absolute C-drive paths are allowed.");
                foreach (string part in path.Substring(3).Split('\\'))
                    if (part == ".." || part == "." || part.EndsWith(".") || part.EndsWith(" "))
                        throw new IOException("Ambiguous path component.");
                path = Path.GetFullPath(path).TrimEnd('\\');
                root = Path.GetFullPath(root).TrimEnd('\\');
                if (!path.StartsWith(root + @"\", StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Deletion must remain below the validated cache root.");
                string parent = Path.GetDirectoryName(path);
                var ancestors = new List<string>();
                while (!String.IsNullOrEmpty(parent)) {
                    ancestors.Add(parent);
                    parent = Path.GetDirectoryName(parent);
                }
                ancestors.Reverse();
                foreach (string ancestor in ancestors) {
                    SafeFileHandle handle = CreateFile(ancestor, ReadAttributes, ShareReadWrite,
                        IntPtr.Zero, OpenExisting, OpenReparse | BackupSemantics, IntPtr.Zero);
                    handles.Add(handle);
                    if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                    FileInfo info = Inspect(handle);
                    if ((info.Attributes & ReparsePoint) != 0 ||
                        (info.Attributes & DirectoryAttribute) == 0)
                        throw new IOException("Unsafe ancestor: reparse point or non-directory.");
                }
                // Refuse existing writers and block new writers during the age
                // check/deletion; ancestor handles may still share writes.
                SafeFileHandle leaf = CreateFile(path, ReadAttributes | DeleteAccess, 1,
                    IntPtr.Zero, OpenExisting, OpenReparse | BackupSemantics, IntPtr.Zero);
                handles.Add(leaf);
                if (leaf.IsInvalid) {
                    int code = Marshal.GetLastWin32Error();
                    if (code == 2 || code == 3) { result.Reason = "NotFound"; return result; }
                    throw new Win32Exception(code);
                }
                FileInfo fileInfo = Inspect(leaf);
                if ((fileInfo.Attributes & ReparsePoint) != 0) {
                    result.Reason = "ReparsePoint"; return result;
                }
                bool directory = (fileInfo.Attributes & DirectoryAttribute) != 0;
                // Child deletion changes a directory's write time; creation time
                // still guards against replacement by a newly created directory.
                if (cutoffFileTime > 0 &&
                    (TimeValue(fileInfo.Creation) > cutoffFileTime ||
                    (!directory && TimeValue(fileInfo.Write) > cutoffFileTime))) {
                    result.Reason = "Recent"; return result;
                }
                // The kernel rejects non-empty directory deletion. No recursive operation.
                var disposition = new Disposition { DeleteFile = true };
                if (!SetFileInformationByHandle(leaf, 4, ref disposition, 1)) {
                    int code = Marshal.GetLastWin32Error();
                    if (directory && code == 145) { result.Reason = "NotEmpty"; return result; }
                    throw new Win32Exception(code);
                }
                result.Removed = true;
                result.Bytes = directory ? 0 : ((long)fileInfo.SizeHigh << 32) | fileInfo.SizeLow;
                result.Reason = "Deleted";
                return result;
            }
            finally {
                for (int i = handles.Count - 1; i >= 0; i--) handles[i].Dispose();
            }
        }
    }
}
'@ -ErrorAction Stop
}
