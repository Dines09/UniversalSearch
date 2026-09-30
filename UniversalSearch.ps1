# Universal Search System - Developed by ETO
# Start with UniversalSearch.cmd, the desktop shortcut, or:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File UniversalSearch.ps1
$SelfPath = $PSCommandPath

# Close the console window that Windows opens for PowerShell; the app itself is a normal window.
Add-Type -Namespace USBoot -Name Con -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("kernel32.dll")] public static extern bool FreeConsole();
'@
$conWin = [USBoot.Con]::GetConsoleWindow()
if ($conWin -ne [IntPtr]::Zero) { [void][USBoot.Con]::ShowWindow($conWin, 0) }
[void][USBoot.Con]::FreeConsole()

# All app output is discarded (there is no console any more).
. {
# ======================= admin settings =======================
$AdminPassword = '1729'          # password for the index settings panel
$AppId         = 'ETO.UniversalSearch'
$DeveloperName  = 'ETO'                 # shown at the end of Help and tips
# ==============================================================

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
try {

$csharp = @'
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace US
{
    public sealed class FileItem
    {
        public string FullName;
        public int NameStart;
        public int ExtPos = -1;
        public bool IsDir;
        public DateTime T;
        public long Size = -1;

        public FileItem(string full, bool isDir, DateTime t, long size)
        {
            FullName = full; IsDir = isDir; T = t; Size = size;
            NameStart = full.LastIndexOf('\\') + 1;
            if (!isDir)
            {
                int d = full.LastIndexOf('.');
                if (d >= NameStart && d < full.Length - 1) ExtPos = d + 1;
            }
        }
        public string Name { get { return FullName.Substring(NameStart); } }
        public string Folder
        {
            get
            {
                if (NameStart <= 0) return "";
                int L = NameStart - 1;
                if (L <= 2) L = NameStart;
                return FullName.Substring(0, L);
            }
        }
    }

    public class IndexData
    {
        public List<FileItem> Items = new List<FileItem>();
        public int MaxDepth;
        public string Meta = "";
        public static int Slashes(string s)
        {
            int c = 0;
            for (int k = 0; k < s.Length; k++) if (s[k] == '\\') c++;
            return c;
        }
        // common drive + this PC, searched together
        public static IndexData Merge(IndexData a, IndexData b)
        {
            if (a == null) return b;
            if (b == null) return a;
            IndexData d = new IndexData();
            d.Items = new List<FileItem>(a.Items.Count + b.Items.Count);
            d.Items.AddRange(a.Items);
            d.Items.AddRange(b.Items);
            d.MaxDepth = a.MaxDepth; d.Meta = a.Meta;
            return d;
        }
    }

    public static class Csv
    {
        public static int Parse(string s, string[] f)
        {
            int n = 0, i = 0, L = s.Length;
            while (n < f.Length)
            {
                if (i < L && s[i] == '"')
                {
                    int st = i + 1, j = st;
                    StringBuilder sb = null;
                    while (true)
                    {
                        int q = s.IndexOf('"', j);
                        if (q < 0)
                        {
                            if (sb == null) f[n] = s.Substring(st); else { sb.Append(s, j, L - j); f[n] = sb.ToString(); }
                            i = L; break;
                        }
                        if (q + 1 < L && s[q + 1] == '"')
                        {
                            if (sb == null) sb = new StringBuilder();
                            sb.Append(s, j, q - j + 1);
                            j = q + 2; continue;
                        }
                        if (sb == null) f[n] = s.Substring(st, q - st); else { sb.Append(s, j, q - j); f[n] = sb.ToString(); }
                        i = q + 1; break;
                    }
                }
                else
                {
                    int c = s.IndexOf(',', i); if (c < 0) c = L;
                    f[n] = s.Substring(i, c - i); i = c;
                }
                n++;
                if (i < L && s[i] == ',') i++; else break;
            }
            return n;
        }

        static int D(string s, int i) { return s[i] - '0'; }
        public static DateTime Date(string s)
        {
            if (s.Length == 19 && s[4] == '-' && s[7] == '-' && s[10] == ' ' && s[13] == ':' && s[16] == ':')
            {
                try
                {
                    return new DateTime(D(s, 0) * 1000 + D(s, 1) * 100 + D(s, 2) * 10 + D(s, 3), D(s, 5) * 10 + D(s, 6), D(s, 8) * 10 + D(s, 9),
                        D(s, 11) * 10 + D(s, 12), D(s, 14) * 10 + D(s, 15), D(s, 17) * 10 + D(s, 18));
                }
                catch (Exception) { }
            }
            DateTime dt;
            if (DateTime.TryParse(s, out dt)) return dt;
            return DateTime.MinValue;
        }
    }

    public class Loader
    {
        public volatile int Count;
        public volatile bool Done;
        public string Error;
        public string Meta = "";
        public IndexData Result;

        public void Start(string path)
        {
            Thread t = new Thread(delegate () { Run(path); });
            t.IsBackground = true;
            t.Start();
        }

        void Run(string path)
        {
            try
            {
                if (IndexFile.IsUsx(path)) { Result = IndexFile.Load(path, this); Meta = Result.Meta; }
                else Result = LoadCsv(path);
            }
            catch (Exception ex) { Error = ex.Message; }
            Done = true;
        }

        // old index format (index.csv) - still readable
        IndexData LoadCsv(string path)
        {
            IndexData d = new IndexData();
            string[] f = new string[5];
            int maxd = 0;
            using (StreamReader sr = new StreamReader(path, Encoding.UTF8, true, 1 << 20))
            {
                string line;
                bool first = true;
                while ((line = sr.ReadLine()) != null)
                {
                    if (first)
                    {
                        first = false;
                        if (line.StartsWith("\"FullName\"") || line.StartsWith("FullName")) continue;
                    }
                    if (line.Length == 0) continue;
                    int n = Csv.Parse(line, f);
                    if (n < 3) continue;
                    bool isDir = n >= 4 && (f[3] == "Folder" || f[3] == "Directory");
                    long size = -1;
                    if (n >= 5 && !long.TryParse(f[4], NumberStyles.Integer, CultureInfo.InvariantCulture, out size)) size = -1;
                    string full = f[0];
                    int c = IndexData.Slashes(full);
                    if (c > maxd) maxd = c;
                    d.Items.Add(new FileItem(full, isDir, Csv.Date(f[2]), isDir ? -1 : size));
                    if ((d.Items.Count & 1023) == 0) Count = d.Items.Count;
                }
            }
            Count = d.Items.Count;
            d.MaxDepth = maxd;
            return d;
        }
    }

    // Index file (.usx): "USX1" + a short text header (when / by whom / what) + a gzip-compressed binary list.
    // Each folder path is stored once, so the file is about 10x smaller than the old CSV and has no row limit.
    public static class IndexFile
    {
        static readonly byte[] Magic = Encoding.ASCII.GetBytes("USX1");

        static bool HasMagic(byte[] b) { return b.Length == 4 && b[0] == Magic[0] && b[1] == Magic[1] && b[2] == Magic[2] && b[3] == Magic[3]; }

        public static bool IsUsx(string path)
        {
            try
            {
                using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    byte[] b = new byte[4];
                    return fs.Read(b, 0, 4) == 4 && HasMagic(b);
                }
            }
            catch (Exception) { return false; }
        }

        // reads only the small header - cheap even over the network
        public static string ReadMeta(string path)
        {
            try
            {
                using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 4096))
                using (BinaryReader br = new BinaryReader(fs, Encoding.UTF8))
                {
                    if (!HasMagic(br.ReadBytes(4))) return null;
                    return br.ReadString();
                }
            }
            catch (Exception) { return null; }
        }

        public static string Get(string meta, string key)
        {
            if (string.IsNullOrEmpty(meta)) return "";
            foreach (string line in meta.Split('\n'))
            {
                int p = line.IndexOf('=');
                if (p > 0 && string.Equals(line.Substring(0, p).Trim(), key, StringComparison.OrdinalIgnoreCase)) return line.Substring(p + 1).Trim();
            }
            return "";
        }

        // "last write time : length" - changes whenever the file is replaced
        public static string Stamp(string path)
        {
            try
            {
                FileInfo fi = new FileInfo(path);
                if (!fi.Exists) return "";
                return fi.LastWriteTimeUtc.Ticks.ToString(CultureInfo.InvariantCulture) + ":" + fi.Length.ToString(CultureInfo.InvariantCulture);
            }
            catch (Exception) { return ""; }
        }

        static void W7(BinaryWriter w, ulong v)
        {
            while (v >= 0x80) { w.Write((byte)(v | 0x80)); v >>= 7; }
            w.Write((byte)v);
        }
        static ulong R7(BinaryReader r)
        {
            ulong v = 0; int sh = 0;
            while (true)
            {
                byte b = r.ReadByte();
                v |= (ulong)(b & 0x7F) << sh;
                if ((b & 0x80) == 0) return v;
                sh += 7;
            }
        }

        public static void Save(string path, List<FileItem> items, string meta)
        {
            string tmp = path + ".tmp";
            using (FileStream fs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16))
            {
                BinaryWriter hw = new BinaryWriter(fs, Encoding.UTF8);
                hw.Write(Magic);
                hw.Write(meta ?? "");
                hw.Flush();
                using (GZipStream gz = new GZipStream(fs, CompressionMode.Compress, true))
                using (BufferedStream bs = new BufferedStream(gz, 1 << 16))
                using (BinaryWriter bw = new BinaryWriter(bs, Encoding.UTF8))
                {
                    Dictionary<string, int> ids = new Dictionary<string, int>(StringComparer.Ordinal);
                    List<string> dirs = new List<string>();
                    int[] di = new int[items.Count];
                    for (int i = 0; i < items.Count; i++)
                    {
                        FileItem it = items[i];
                        string d = it.FullName.Substring(0, it.NameStart);
                        int id;
                        if (!ids.TryGetValue(d, out id)) { id = dirs.Count; ids[d] = id; dirs.Add(d); }
                        di[i] = id;
                    }
                    bw.Write(dirs.Count);
                    foreach (string d in dirs) bw.Write(d);
                    bw.Write(items.Count);
                    for (int i = 0; i < items.Count; i++)
                    {
                        FileItem it = items[i];
                        W7(bw, (ulong)di[i]);
                        bw.Write(it.FullName.Substring(it.NameStart));
                        bw.Write((byte)(it.IsDir ? 1 : 0));
                        W7(bw, (ulong)(it.T.Ticks / TimeSpan.TicksPerSecond));
                        W7(bw, (ulong)(it.Size + 1));
                    }
                }
            }
            Replace(tmp, path);
        }

        public static IndexData Load(string path, Loader progress)
        {
            IndexData d = new IndexData();
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16))
            {
                BinaryReader hr = new BinaryReader(fs, Encoding.UTF8);
                if (!HasMagic(hr.ReadBytes(4))) throw new InvalidDataException("Not an index file");
                d.Meta = hr.ReadString();
                using (GZipStream gz = new GZipStream(fs, CompressionMode.Decompress, true))
                using (BufferedStream bs = new BufferedStream(gz, 1 << 16))
                using (BinaryReader br = new BinaryReader(bs, Encoding.UTF8))
                {
                    int nd = br.ReadInt32();
                    string[] dirs = new string[nd];
                    int[] depth = new int[nd];
                    int maxd = 0;
                    for (int i = 0; i < nd; i++)
                    {
                        dirs[i] = br.ReadString();
                        depth[i] = IndexData.Slashes(dirs[i]);
                        if (depth[i] > maxd) maxd = depth[i];
                    }
                    int n = br.ReadInt32();
                    d.Items = new List<FileItem>(n);
                    for (int i = 0; i < n; i++)
                    {
                        int id = (int)R7(br);
                        string name = br.ReadString();
                        byte fl = br.ReadByte();
                        long secs = (long)R7(br);
                        long size = (long)R7(br) - 1;
                        d.Items.Add(new FileItem(dirs[id] + name, (fl & 1) != 0, new DateTime(secs * TimeSpan.TicksPerSecond), size));
                        if (progress != null && (i & 4095) == 0) progress.Count = i;
                    }
                    d.MaxDepth = maxd;
                }
            }
            if (progress != null) progress.Count = d.Items.Count;
            return d;
        }

        // replace dst with src; retries while another PC is still copying the old file
        public static void Replace(string src, string dst)
        {
            for (int attempt = 0; ; attempt++)
            {
                try
                {
                    if (File.Exists(dst)) File.Delete(dst);
                    File.Move(src, dst);
                    return;
                }
                catch (Exception)
                {
                    if (attempt >= 30) throw;
                    Thread.Sleep(500);
                }
            }
        }

        // copy to the shared folder under a temporary name first, so nobody ever reads a half-written index
        public static void Publish(string local, string shared)
        {
            string tmp = shared + ".new";
            File.Copy(local, tmp, true);
            Replace(tmp, shared);
        }
    }

    // Background check of the shared index: only the file date/size is read unless it really changed.
    public sealed class SyncJob
    {
        public volatile bool Done;
        public volatile int Percent;
        public string State = "";      // same | copied | missing | error
        public string Error = "", Stamp = "", Download = "";

        public static SyncJob Start(string master, string cache, string known)
        {
            SyncJob j = new SyncJob();
            Thread t = new Thread(delegate () { j.Run(master, cache, known); });
            t.IsBackground = true;
            t.Priority = ThreadPriority.BelowNormal;
            t.Start();
            return j;
        }

        void Run(string master, string cache, string known)
        {
            try
            {
                string st = IndexFile.Stamp(master);
                if (st == "") { State = "missing"; return; }
                if (st == known && File.Exists(cache)) { State = "same"; return; }
                string dl = cache + ".download";
                for (int attempt = 0; attempt < 3; attempt++)
                {
                    Copy(master, dl);
                    string again = IndexFile.Stamp(master);
                    if (again == st) break;
                    st = again;                 // replaced while we were copying - copy the new one
                }
                if (!IndexFile.IsUsx(dl)) { try { File.Delete(dl); } catch (Exception) { } State = "error"; Error = "The shared index file is damaged."; return; }
                Stamp = st; Download = dl; State = "copied";
            }
            catch (Exception ex) { State = "error"; Error = ex.Message; }
            finally { Done = true; }
        }

        void Copy(string src, string dst)
        {
            using (FileStream a = new FileStream(src, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16))
            using (FileStream b = new FileStream(dst, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16))
            {
                long total = a.Length, done = 0;
                byte[] buf = new byte[1 << 20];
                int n;
                while ((n = a.Read(buf, 0, buf.Length)) > 0)
                {
                    b.Write(buf, 0, n);
                    done += n;
                    Percent = total > 0 ? (int)(done * 100 / total) : 0;
                }
            }
        }
    }

    class Job { public string Dir; public int Depth; }

    // Multi-threaded scanner: many threads list different folders at the same time.
    public class Indexer
    {
        public int Count;
        public volatile bool Done;
        public volatile bool Cancel;
        public volatile string Phase = "Scanning";
        public string Error, PublishError, Meta = "", PublishedStamp = "";
        public IndexData Result;

        ConcurrentQueue<Job> q = new ConcurrentQueue<Job>();
        int pending;
        int maxDepth;
        bool skipSys;
        HashSet<string> exts;
        List<FileItem> all = new List<FileItem>();

        // "This PC": folders that only hold Windows / program / system files
        static readonly HashSet<string> RootSkip = new HashSet<string>(new string[] {
            "Windows", "Windows.old", "Program Files", "Program Files (x86)", "ProgramData", "PerfLogs", "Recovery", "MSOCache",
            "Config.Msi", "OneDriveTemp", "inetpub", "Intel", "AMD", "NVIDIA", "Drivers", "ESD", "$WinREAgent", "$SysReset",
            "$Windows.~BT", "$Windows.~WS", "$GetCurrent" }, StringComparer.OrdinalIgnoreCase);
        static readonly HashSet<string> AnySkip = new HashSet<string>(new string[] {
            "AppData", "Application Data", "Local Settings", "$Recycle.Bin", "System Volume Information", "node_modules",
            ".git", ".svn", ".hg", "__pycache__", ".cache", ".vscode", ".nuget", ".gradle", ".m2", "site-packages" }, StringComparer.OrdinalIgnoreCase);
        static readonly HashSet<string> UsersSkip = new HashSet<string>(new string[] {
            "Default", "Default User", "All Users", "defaultuser0", "defaultuser100000" }, StringComparer.OrdinalIgnoreCase);

        // outPath: where the index is written. publishPath: shared copy for the other PCs (or null). cachePath: final local copy (or null).
        public void Start(string[] roots, int depth, int threads, string outPath, string publishPath, string cachePath, string meta, bool skipSystem, string allowExts)
        {
            maxDepth = depth;
            skipSys = skipSystem;
            if (!string.IsNullOrEmpty(allowExts))
            {
                exts = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (string x in allowExts.Split(new char[] { ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries)) exts.Add(x.Trim().TrimStart('.'));
            }
            Thread t = new Thread(delegate () { Run(roots, threads, outPath, publishPath, cachePath, meta); });
            t.IsBackground = true;
            t.Start();
        }

        void Run(string[] roots, int threads, string outPath, string publishPath, string cachePath, string meta)
        {
            try
            {
                foreach (string r in roots)
                {
                    Interlocked.Increment(ref pending);
                    q.Enqueue(new Job { Dir = r, Depth = 1 });
                }
                List<Thread> ws = new List<Thread>();
                for (int i = 0; i < threads; i++)
                {
                    Thread w = new Thread(Worker);
                    w.IsBackground = true;
                    w.Start();
                    ws.Add(w);
                }
                foreach (Thread w in ws) w.Join();

                if (!Cancel)
                {
                    Phase = "Sorting";
                    all.Sort(delegate (FileItem a, FileItem b) { return string.Compare(a.FullName, b.FullName, StringComparison.OrdinalIgnoreCase); });
                    int maxd = 0;
                    foreach (FileItem it in all) { int c = IndexData.Slashes(it.FullName); if (c > maxd) maxd = c; }
                    Phase = "Saving";
                    string m = (meta ?? "") + "\nitems=" + all.Count.ToString(CultureInfo.InvariantCulture);
                    IndexFile.Save(outPath, all, m);
                    Meta = m;
                    if (!string.IsNullOrEmpty(publishPath))
                    {
                        Phase = "Saving to the shared folder";
                        try { IndexFile.Publish(outPath, publishPath); PublishedStamp = IndexFile.Stamp(publishPath); }
                        catch (Exception ex) { PublishError = ex.Message; }
                    }
                    if (!string.IsNullOrEmpty(cachePath) && !string.Equals(cachePath, outPath, StringComparison.OrdinalIgnoreCase)) IndexFile.Replace(outPath, cachePath);
                    IndexData d = new IndexData();
                    d.Items = all;
                    d.MaxDepth = maxd;
                    d.Meta = m;
                    Result = d;
                }
            }
            catch (Exception ex) { Error = ex.Message; }
            Done = true;
        }

        void Worker()
        {
            List<FileItem> local = new List<FileItem>();
            while (!Cancel)
            {
                Job j;
                if (!q.TryDequeue(out j))
                {
                    if (Thread.VolatileRead(ref pending) == 0) break;
                    Thread.Sleep(2);
                    continue;
                }
                try { Process(j, local); }
                catch (Exception) { }
                finally { Interlocked.Decrement(ref pending); }
            }
            lock (all) { all.AddRange(local); }
        }

        bool SkipDir(Job j, string name)
        {
            if (AnySkip.Contains(name)) return true;
            if (j.Dir.Length <= 3 && RootSkip.Contains(name)) return true;
            if (UsersSkip.Contains(name) && j.Dir.TrimEnd('\\').EndsWith("\\Users", StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        void Process(Job j, List<FileItem> local)
        {
            DirectoryInfo di = new DirectoryInfo(j.Dir);
            foreach (FileSystemInfo fi in di.EnumerateFileSystemInfos())
            {
                FileAttributes a = fi.Attributes;
                bool isDir = (a & FileAttributes.Directory) != 0;
                if (skipSys)
                {
                    if ((a & FileAttributes.Hidden) != 0 && (a & FileAttributes.System) != 0) continue;
                    if (isDir && SkipDir(j, fi.Name)) continue;
                }
                if (!isDir && exts != null)
                {
                    string nm = fi.Name;
                    int d = nm.LastIndexOf('.');
                    if (d < 0 || d == nm.Length - 1 || !exts.Contains(nm.Substring(d + 1))) continue;
                }
                long size = -1;
                if (!isDir) { FileInfo fl = fi as FileInfo; if (fl != null) size = fl.Length; }
                local.Add(new FileItem(fi.FullName, isDir, fi.LastWriteTime, size));
                Interlocked.Increment(ref Count);
                if (isDir && (a & FileAttributes.ReparsePoint) == 0 && j.Depth < maxDepth)
                {
                    Interlocked.Increment(ref pending);
                    q.Enqueue(new Job { Dir = fi.FullName, Depth = j.Depth + 1 });
                }
            }
        }
    }

    // ---------------------------------------------------------------- search
    public sealed class Query
    {
        public string Raw = "";
        public string[] Terms = new string[0];   // upper-case, longest first
        public string[] Excl = new string[0];
        public string[] Exts;                    // upper-case, null = any
        public int Kind;                         // 0 all, 1 files, 2 folders
        public bool PathScope;
        public int[] Years;                      // null = all years
        public string Key = "";

        public bool IsEmpty { get { return Terms.Length == 0 && Excl.Length == 0 && Exts == null && Years == null; } }

        static readonly char[] ListSep = new char[] { ',', ';', '|' };
        static readonly char[] Wild = new char[] { '*', '?' };

        public static Query Parse(string text, int kind, bool pathScope, string category, int[] years)
        {
            Query q = new Query();
            q.Raw = (text ?? "").Trim();
            q.Kind = kind; q.PathScope = pathScope; q.Years = (years != null && years.Length > 0) ? years : null;
            List<string> terms = new List<string>(), excl = new List<string>(), exts = new List<string>();
            string s = q.Raw; int i = 0, L = s.Length;
            while (i < L)
            {
                char c = s[i];
                if (char.IsWhiteSpace(c)) { i++; continue; }
                bool neg = false;
                if (c == '-' && i + 1 < L && s[i + 1] == '"') { neg = true; i++; c = '"'; }
                if (c == '"')
                {
                    int e = s.IndexOf('"', i + 1); if (e < 0) e = L;
                    string ph = s.Substring(i + 1, e - i - 1);
                    if (ph.Length > 0) (neg ? excl : terms).Add(ph.ToUpperInvariant());
                    i = e + 1; continue;
                }
                int st = i;
                while (i < L && !char.IsWhiteSpace(s[i])) i++;
                string w = s.Substring(st, i - st);
                if (w.StartsWith("ext:", StringComparison.OrdinalIgnoreCase))
                {
                    foreach (string x in w.Substring(4).Split(ListSep, StringSplitOptions.RemoveEmptyEntries))
                    {
                        string t = x.TrimStart('.', '*');
                        if (t.Length > 0) exts.Add(t.ToUpperInvariant());
                    }
                    continue;
                }
                if (w.Length > 2 && w.StartsWith("*.") && w.IndexOfAny(Wild, 1) < 0) { exts.Add(w.Substring(2).ToUpperInvariant()); continue; }
                bool ex = w.Length > 1 && w[0] == '-';
                foreach (string p in (ex ? w.Substring(1) : w).Split(Wild, StringSplitOptions.RemoveEmptyEntries))
                    (ex ? excl : terms).Add(p.ToUpperInvariant());
            }
            if (exts.Count == 0 && !string.IsNullOrEmpty(category))
                foreach (string x in category.Split(ListSep, StringSplitOptions.RemoveEmptyEntries)) exts.Add(x.Trim().ToUpperInvariant());
            terms.Sort(delegate (string a, string b) { return b.Length - a.Length; });
            q.Terms = terms.ToArray();
            q.Excl = excl.ToArray();
            q.Exts = exts.Count > 0 ? exts.ToArray() : null;
            q.Key = kind + "|" + (q.Years == null ? "*" : string.Join(",", q.Years)) + "|" + (pathScope ? "P" : "N") + "|" + string.Join("\u0001", q.Terms) + "|" + string.Join("\u0001", q.Excl) + "|" + (q.Exts == null ? "*" : string.Join(",", q.Exts));
            return q;
        }

        // True when every result of this query is also a result of 'o' - then we only need to filter o's results.
        public bool Narrows(Query o)
        {
            if (o.PathScope != PathScope) return false;
            if (o.Kind != 0 && o.Kind != Kind) return false;
            if (o.Years != null)
            {
                if (Years == null) return false;
                foreach (int y in Years) if (Array.IndexOf(o.Years, y) < 0) return false;
            }
            foreach (string t in o.Terms)
            {
                bool ok = false;
                foreach (string n in Terms) if (n.IndexOf(t, StringComparison.Ordinal) >= 0) { ok = true; break; }
                if (!ok) return false;
            }
            foreach (string x in o.Excl)
            {
                bool ok = false;
                foreach (string n in Excl) if (x.IndexOf(n, StringComparison.Ordinal) >= 0) { ok = true; break; }
                if (!ok) return false;
            }
            if (o.Exts != null)
            {
                if (Exts == null) return false;
                foreach (string e in Exts) if (Array.IndexOf(o.Exts, e) < 0) return false;
            }
            return true;
        }
    }

    public static class Matcher
    {
        static readonly char[] Up = new char[128];
        static Matcher() { for (int i = 0; i < 128; i++) Up[i] = char.ToUpperInvariant((char)i); }

        public static int Find(string s, int start, string up)
        {
            int m = up.Length;
            if (m == 0) return start;
            int last = s.Length - m;
            char f = up[0];
            for (int i = start; i <= last; i++)
            {
                char c = s[i];
                c = c < 128 ? Up[c] : char.ToUpperInvariant(c);
                if (c != f) continue;
                int k = 1;
                for (; k < m; k++)
                {
                    char d = s[i + k];
                    d = d < 128 ? Up[d] : char.ToUpperInvariant(d);
                    if (d != up[k]) break;
                }
                if (k == m) return i;
            }
            return -1;
        }

        static bool EqTail(string s, int pos, string up)
        {
            if (s.Length - pos != up.Length) return false;
            for (int k = 0; k < up.Length; k++)
            {
                char c = s[pos + k];
                c = c < 128 ? Up[c] : char.ToUpperInvariant(c);
                if (c != up[k]) return false;
            }
            return true;
        }

        static bool IsSep(char c)
        {
            return c == ' ' || c == '_' || c == '-' || c == '.' || c == '(' || c == '[' || c == '\\' || c == ',' || c == '+' || c == '&';
        }

        public static bool Match(FileItem it, Query q, out int score)
        {
            score = 0;
            if (q.Kind == 1 && it.IsDir) return false;
            if (q.Kind == 2 && !it.IsDir) return false;
            if (q.Years != null && Array.IndexOf(q.Years, it.T.Year) < 0) return false;
            string s = it.FullName;
            int ns = it.NameStart;
            string[] ex = q.Exts;
            if (ex != null)
            {
                if (it.ExtPos < 0) return false;
                bool ok = false;
                for (int k = 0; k < ex.Length; k++) if (EqTail(s, it.ExtPos, ex[k])) { ok = true; break; }
                if (!ok) return false;
            }
            int from = q.PathScope ? 0 : ns;
            string[] t = q.Terms;
            int sc = 0; bool allName = true; bool exactStart = false;
            for (int k = 0; k < t.Length; k++)
            {
                int p = Find(s, from, t[k]);
                if (p < 0) return false;
                if (p < ns)
                {
                    p = Find(s, ns, t[k]);
                    if (p < 0) { allName = false; continue; }
                }
                if (p == ns) { sc += 400; if (t.Length == 1) exactStart = true; }
                else if (IsSep(s[p - 1]) || (char.IsLower(s[p - 1]) && char.IsUpper(s[p]))) sc += 150;
                else sc += 40;
            }
            string[] xs = q.Excl;
            for (int k = 0; k < xs.Length; k++) if (Find(s, from, xs[k]) >= 0) return false;

            int nameLen = s.Length - ns;
            if (t.Length > 0 && allName) sc += 1000;
            if (exactStart)
            {
                int baseLen = (it.ExtPos > 0 ? it.ExtPos - 1 : s.Length) - ns;
                if (nameLen == t[0].Length || baseLen == t[0].Length) sc += 3000;
            }
            sc -= Math.Min(nameLen, 200);
            score = sc;
            return true;
        }
    }

    public sealed class Hit
    {
        public FileItem It;
        public int Score;
        public int Ord;
        public Hit(FileItem it, int score, int ord) { It = it; Score = score; Ord = ord; }
    }

    public static class Sorter
    {
        static char U(char c) { return char.ToUpperInvariant(c); }

        // Natural, case-insensitive compare (file2 before file10), like Explorer.
        public static int Nat(string a, int ai, int ae, string b, int bi, int be)
        {
            while (ai < ae && bi < be)
            {
                char ca = a[ai], cb = b[bi];
                bool da = ca >= '0' && ca <= '9', db = cb >= '0' && cb <= '9';
                if (da && db)
                {
                    int sa = ai; while (sa < ae && a[sa] == '0') sa++;
                    int sb = bi; while (sb < be && b[sb] == '0') sb++;
                    int ea = sa; while (ea < ae && a[ea] >= '0' && a[ea] <= '9') ea++;
                    int eb = sb; while (eb < be && b[eb] >= '0' && b[eb] <= '9') eb++;
                    int la = ea - sa, lb = eb - sb;
                    if (la != lb) return la - lb;
                    for (int k = 0; k < la; k++) if (a[sa + k] != b[sb + k]) return a[sa + k] - b[sb + k];
                    ai = ea; bi = eb; continue;
                }
                ca = U(ca); cb = U(cb);
                if (ca != cb) return ca < cb ? -1 : 1;
                ai++; bi++;
            }
            return (ae - ai) - (be - bi);
        }

        static int NameCmp(FileItem a, FileItem b) { return Nat(a.FullName, a.NameStart, a.FullName.Length, b.FullName, b.NameStart, b.FullName.Length); }
        static int FolderCmp(FileItem a, FileItem b) { return Nat(a.FullName, 0, Math.Max(0, a.NameStart - 1), b.FullName, 0, Math.Max(0, b.NameStart - 1)); }

        // col: 0 none (search order), 1 name, 2 path, 3 size, 4 modified, 5 type, 6 full path, 9 best match
        public static Comparison<Hit> Get(int col, bool desc)
        {
            int sg = desc ? -1 : 1;
            switch (col)
            {
                case 1: return delegate (Hit a, Hit b) { int r = NameCmp(a.It, b.It); return r != 0 ? sg * r : a.Ord.CompareTo(b.Ord); };
                case 2: return delegate (Hit a, Hit b) { int r = FolderCmp(a.It, b.It); if (r == 0) r = NameCmp(a.It, b.It); return r != 0 ? sg * r : a.Ord.CompareTo(b.Ord); };
                case 3: return delegate (Hit a, Hit b) { int r = a.It.Size.CompareTo(b.It.Size); return r != 0 ? sg * r : a.Ord.CompareTo(b.Ord); };
                case 4: return delegate (Hit a, Hit b) { int r = a.It.T.CompareTo(b.It.T); return r != 0 ? sg * r : a.Ord.CompareTo(b.Ord); };
                case 5: return delegate (Hit a, Hit b)
                {
                    int r = b.It.IsDir.CompareTo(a.It.IsDir);
                    if (r == 0)
                    {
                        string x = a.It.FullName, y = b.It.FullName;
                        r = Nat(x, a.It.ExtPos < 0 ? x.Length : a.It.ExtPos, x.Length, y, b.It.ExtPos < 0 ? y.Length : b.It.ExtPos, y.Length);
                    }
                    if (r == 0) r = NameCmp(a.It, b.It);
                    return r != 0 ? sg * r : a.Ord.CompareTo(b.Ord);
                };
                case 6: return delegate (Hit a, Hit b) { int r = Nat(a.It.FullName, 0, a.It.FullName.Length, b.It.FullName, 0, b.It.FullName.Length); return r != 0 ? sg * r : a.Ord.CompareTo(b.Ord); };
                case 9: return delegate (Hit a, Hit b) { if (a.Score != b.Score) return a.Score > b.Score ? -1 : 1; return a.Ord.CompareTo(b.Ord); };
                default: return delegate (Hit a, Hit b) { return a.Ord.CompareTo(b.Ord); };
            }
        }
    }

    // Runs searches on background threads (all CPU cores), newest request wins.
    public sealed class Searcher
    {
        readonly ListView list;
        readonly TextBlock lblCount, lblTime, emptyText;
        readonly FrameworkElement empty;
        readonly object sync = new object();
        IndexData index;
        int gen;
        Query lastQ; List<Hit> lastRaw; IndexData lastIdx;
        string shownKey;

        public int SortCol;
        public bool SortDesc;
        public Query Current;

        public Searcher(ListView l, TextBlock count, TextBlock time, FrameworkElement emptyPanel, TextBlock emptyTb)
        {
            list = l; lblCount = count; lblTime = time; empty = emptyPanel; emptyText = emptyTb;
        }

        public IndexData Index { get { return index; } }

        public void SetIndex(IndexData d)
        {
            index = d;
            lock (sync) { lastQ = null; lastRaw = null; lastIdx = null; }
        }

        public void Clear()
        {
            Interlocked.Increment(ref gen);
            Current = null; shownKey = null;
            list.ItemsSource = null;
            empty.Visibility = Visibility.Collapsed;
            lblCount.Text = ""; lblTime.Text = "";
        }

        public bool Run(Query q)
        {
            if (index == null || q == null) return false;
            Current = q;
            int g = Interlocked.Increment(ref gen);
            IndexData idx = index; int sc = SortCol; bool sd = SortDesc;
            Task.Factory.StartNew(() => Work(g, idx, q, sc, sd));
            return true;
        }

        bool Stale(int g) { return Thread.VolatileRead(ref gen) != g; }

        void Work(int g, IndexData idx, Query q, int sc, bool sd)
        {
            try
            {
                Stopwatch sw = Stopwatch.StartNew();
                Query pq; List<Hit> praw; IndexData pidx;
                lock (sync) { pq = lastQ; praw = lastRaw; pidx = lastIdx; }
                if (pidx != idx) { pq = null; praw = null; }
                List<Hit> raw;
                if (pq != null && pq.Key == q.Key) raw = praw;
                else
                {
                    raw = Filter(g, idx, q, (pq != null && q.Narrows(pq)) ? praw : null);
                    if (raw == null) return;
                    lock (sync) { lastQ = q; lastRaw = raw; lastIdx = idx; }
                }
                if (Stale(g)) return;
                List<Hit> view = raw;
                if (sc != 0)
                {
                    view = new List<Hit>(raw);
                    view.Sort(Sorter.Get(sc, sd));
                }
                if (Stale(g)) return;
                long ms = sw.ElapsedMilliseconds;
                list.Dispatcher.BeginInvoke(new Action(delegate { Publish(g, q, view, ms); }));
            }
            catch (Exception ex)
            {
                string m = ex.Message;
                list.Dispatcher.BeginInvoke(new Action(delegate { if (!Stale(g)) lblCount.Text = "Search error: " + m; }));
            }
        }

        List<Hit> Filter(int g, IndexData idx, Query q, List<Hit> prev)
        {
            List<FileItem> items = idx.Items;
            int n = prev != null ? prev.Count : items.Count;
            const int chunk = 8192;
            int nChunks = (n + chunk - 1) / chunk;
            List<Hit>[] parts = new List<Hit>[nChunks];
            bool cancelled = false;
            ParallelOptions po = new ParallelOptions();
            po.MaxDegreeOfParallelism = Environment.ProcessorCount;
            Parallel.For(0, nChunks, po, delegate (int c, ParallelLoopState st)
            {
                if (Stale(g)) { cancelled = true; st.Stop(); return; }
                int a = c * chunk, b = Math.Min(n, a + chunk);
                List<Hit> res = new List<Hit>();
                for (int i = a; i < b; i++)
                {
                    FileItem it; int ord;
                    if (prev != null) { Hit h = prev[i]; it = h.It; ord = h.Ord; } else { it = items[i]; ord = i; }
                    int sc;
                    if (Matcher.Match(it, q, out sc)) res.Add(new Hit(it, sc, ord));
                }
                parts[c] = res;
            });
            if (cancelled || Stale(g)) return null;
            int total = 0;
            foreach (List<Hit> p in parts) if (p != null) total += p.Count;
            List<Hit> all = new List<Hit>(total);
            foreach (List<Hit> p in parts) if (p != null) all.AddRange(p);
            return all;
        }

        void Publish(int g, Query q, List<Hit> view, long ms)
        {
            if (Stale(g)) return;
            bool same = shownKey == q.Key;
            shownKey = q.Key;
            object sel = same ? list.SelectedItem : null;
            Ui.Terms = q.Terms;
            Ui.HlPath = q.PathScope;
            list.ItemsSource = view;
            lblCount.Text = view.Count.ToString("N0") + (view.Count == 1 ? " result" : " results");
            lblTime.Text = ms < 1 ? "in <1 ms" : "in " + ms.ToString("N0") + " ms";
            if (view.Count == 0)
            {
                emptyText.Text = "No results for \u201C" + q.Raw + "\u201D";
                empty.Visibility = Visibility.Visible;
            }
            else empty.Visibility = Visibility.Collapsed;
            if (sel != null) { list.SelectedItem = sel; list.ScrollIntoView(sel); }
            else if (view.Count > 0) list.ScrollIntoView(view[0]);
        }
    }

    // ---------------------------------------------------------------- UI helpers
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHFILEINFO
    {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHELLEXECUTEINFO
    {
        public int cbSize; public uint fMask; public IntPtr hwnd;
        public string lpVerb; public string lpFile; public string lpParameters; public string lpDirectory;
        public int nShow; public IntPtr hInstApp; public IntPtr lpIDList; public string lpClass;
        public IntPtr hkeyClass; public uint dwHotKey; public IntPtr hIcon; public IntPtr hProcess;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PropertyKey { public Guid fmtid; public uint pid; }

    [StructLayout(LayoutKind.Explicit)]
    public struct PropVariant
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr p;
        [FieldOffset(16)] public IntPtr pad;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore
    {
        int GetCount(out uint c);
        int GetAt(uint i, out PropertyKey k);
        int GetValue(ref PropertyKey k, out PropVariant v);
        int SetValue(ref PropertyKey k, ref PropVariant v);
        int Commit();
    }

    public sealed class OpenJob
    {
        public volatile bool Done;
        public volatile string Error;
    }

    // One thumbnail request. Finished jobs call back on the UI thread; cancelled jobs are skipped.
    public sealed class ThumbJob
    {
        public volatile bool Cancel;
        public string Path;
        public int Size;
        public Dispatcher Disp;
        public Action<ThumbJob> OnDone;
        public ImageSource Image;
    }

    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory
    {
        int GetImage(SIZE size, int flags, out IntPtr phbm);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SIZE { public int cx; public int cy; public SIZE(int a, int b) { cx = a; cy = b; } }

    // Thumbnails from the Windows Shell (the same ones Explorer shows). Three background workers only;
    // the newest request is served first, so what is on screen now loads before what was scrolled past.
    public static class Thumbs
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        static extern void SHCreateItemFromParsingName([MarshalAs(UnmanagedType.LPWStr)] string path, IntPtr bc, [In] ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory ppv);
        [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);

        static Guid IID_Factory = new Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b");
        const int Workers = 3;
        const int CacheMax = 600;

        static readonly object gate = new object();
        static readonly LinkedList<ThumbJob> queue = new LinkedList<ThumbJob>();
        static bool started;

        // finished thumbnails, used only on the UI thread
        static readonly Dictionary<string, ImageSource> cache = new Dictionary<string, ImageSource>(StringComparer.OrdinalIgnoreCase);
        static readonly Queue<string> cacheOrder = new Queue<string>();

        public static ImageSource Cached(string path)
        {
            ImageSource s;
            return cache.TryGetValue(path, out s) ? s : null;
        }
        public static void Remember(string path, ImageSource img)
        {
            if (img == null || cache.ContainsKey(path)) return;
            cache[path] = img;
            cacheOrder.Enqueue(path);
            while (cacheOrder.Count > CacheMax) cache.Remove(cacheOrder.Dequeue());
        }

        public static ThumbJob Request(string path, int size, Dispatcher disp, Action<ThumbJob> done)
        {
            ThumbJob j = new ThumbJob();
            j.Path = path; j.Size = size; j.Disp = disp; j.OnDone = done;
            lock (gate)
            {
                if (!started)
                {
                    started = true;
                    for (int i = 0; i < Workers; i++)
                    {
                        Thread t = new Thread(Work);
                        t.IsBackground = true;
                        t.SetApartmentState(ApartmentState.STA);
                        t.Priority = ThreadPriority.BelowNormal;
                        t.Start();
                    }
                }
                queue.AddFirst(j);
                // do not let a huge backlog build up: drop the oldest waiting requests
                while (queue.Count > 400) { queue.Last.Value.Cancel = true; queue.RemoveLast(); }
                Monitor.Pulse(gate);
            }
            return j;
        }

        static void Work()
        {
            while (true)
            {
                ThumbJob j;
                lock (gate)
                {
                    while (queue.Count == 0) Monitor.Wait(gate);
                    j = queue.First.Value;
                    queue.RemoveFirst();
                }
                if (j.Cancel) continue;
                try { j.Image = Make(j.Path, j.Size); } catch (Exception) { }
                if (j.Cancel || j.Disp == null) continue;
                ThumbJob done = j;
                try { j.Disp.BeginInvoke(DispatcherPriority.Background, new Action(delegate { if (!done.Cancel && done.OnDone != null) done.OnDone(done); })); }
                catch (Exception) { }
            }
        }

        static ImageSource Make(string path, int size)
        {
            IShellItemImageFactory f;
            SHCreateItemFromParsingName(path, IntPtr.Zero, ref IID_Factory, out f);
            if (f == null) return null;
            IntPtr hbm = IntPtr.Zero;
            try
            {
                if (f.GetImage(new SIZE(size, size), 0, out hbm) != 0 || hbm == IntPtr.Zero) return null;
                BitmapSource bs = Imaging.CreateBitmapSourceFromHBitmap(hbm, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                bs.Freeze();
                return bs;
            }
            finally
            {
                if (hbm != IntPtr.Zero) DeleteObject(hbm);
                Marshal.ReleaseComObject(f);
            }
        }
    }

    // The grid is a virtualized list of ROWS; each row holds up to Cols images. Only rows on screen are built,
    // and rows are added a page at a time as the user scrolls, so thousands of results never freeze the window.
    public sealed class GridPager
    {
        public readonly System.Collections.ObjectModel.ObservableCollection<Hit[]> Rows = new System.Collections.ObjectModel.ObservableCollection<Hit[]>();
        IList<Hit> src;
        int next;
        int cols = 6;
        public object Source { get { return src; } }
        public int Total { get { return src == null ? 0 : src.Count; } }
        public int Count { get { return next; } }
        public int Cols { get { return cols; } }
        public bool HasMore { get { return src != null && next < src.Count; } }

        public void SetSource(IList<Hit> s, int first)
        {
            src = s; next = 0;
            Rows.Clear();
            More(first);
        }

        // add at least n more images (whole rows)
        public void More(int n)
        {
            if (src == null) return;
            int target = Math.Min(src.Count, next + Math.Max(n, 1));
            while (next < target)
            {
                int k = Math.Min(cols, src.Count - next);
                Hit[] row = new Hit[k];
                for (int i = 0; i < k; i++) row[i] = src[next + i];
                Rows.Add(row);
                next += k;
            }
        }

        // window resized: re-flow the same images into rows of the new width
        public bool SetCols(int c)
        {
            if (c < 1) c = 1;
            if (c == cols) return false;
            cols = c;
            int shown = next;
            next = 0;
            Rows.Clear();
            More(shown);
            return true;
        }
    }

    public static class Ui
    {
        // ---- right-click menus: open to the right of the cursor, no tooltips while a menu is open ----
        public static bool MenuOpen;
        [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);

        public static void SetupMenus()
        {
            // Windows "right-handed" setting makes menus open to the LEFT of the mouse; open them to the right instead
            try
            {
                System.Reflection.FieldInfo f = typeof(SystemParameters).GetField("_menuDropAlignment", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static);
                if (f != null && SystemParameters.MenuDropAlignment) f.SetValue(null, false);
            }
            catch (Exception) { }
            // while a menu is open, the name/path tooltips of pictures and rows stay hidden
            EventManager.RegisterClassHandler(typeof(FrameworkElement), FrameworkElement.ToolTipOpeningEvent,
                new ToolTipEventHandler(delegate (object s, ToolTipEventArgs e) { if (MenuOpen) e.Handled = true; }), true);
        }

        // put the mouse pointer on a menu item (fx = how far across the item, 0..1)
        public static void PointAt(FrameworkElement el, double fx)
        {
            try
            {
                if (el == null || el.ActualWidth <= 0 || PresentationSource.FromVisual(el) == null) return;
                Point p = el.PointToScreen(new Point(el.ActualWidth * fx, el.ActualHeight / 2));
                SetCursorPos((int)p.X, (int)p.Y);
            }
            catch (Exception) { }
        }

        public static string[] Terms = new string[0];
        public static bool HlPath = true;

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr SHGetFileInfo(string path, uint attr, ref SHFILEINFO fi, uint cb, uint flags);
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern bool ShellExecuteEx(ref SHELLEXECUTEINFO i);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SetCurrentProcessExplicitAppUserModelID(string id);
        [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore ps);

        // Taskbar identity for this window, so "Pin to taskbar" pins the app (lens icon, silent launch) instead of PowerShell.
        public static void SetWindowAppProps(IntPtr hwnd, string appId, string relaunchCmd, string iconRes, string name)
        {
            try
            {
                Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
                IPropertyStore ps;
                if (SHGetPropertyStoreForWindow(hwnd, ref iid, out ps) != 0 || ps == null) return;
                Guid fmt = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
                SetStr(ps, fmt, 5, appId);
                if (!string.IsNullOrEmpty(relaunchCmd))
                {
                    SetStr(ps, fmt, 2, relaunchCmd);
                    SetStr(ps, fmt, 3, iconRes);
                    SetStr(ps, fmt, 4, name);
                }
                ps.Commit();
                Marshal.ReleaseComObject(ps);
            }
            catch (Exception) { }
        }
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, IntPtr pid);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hwnd);

        public static void BringToFront(IntPtr hwnd)
        {
            try
            {
                IntPtr fg = GetForegroundWindow();
                uint fgThread = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, IntPtr.Zero);
                uint me = GetCurrentThreadId();
                bool attached = fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, true);
                BringWindowToTop(hwnd);
                SetForegroundWindow(hwnd);
                if (attached) AttachThreadInput(me, fgThread, false);
            }
            catch (Exception) { }
        }

        public static string ReadWindowProp(IntPtr hwnd, uint pid)
        {
            try
            {
                Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
                IPropertyStore ps;
                if (SHGetPropertyStoreForWindow(hwnd, ref iid, out ps) != 0 || ps == null) return "(no store)";
                PropertyKey k = new PropertyKey(); k.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); k.pid = pid;
                PropVariant v;
                int hr = ps.GetValue(ref k, out v);
                string r = (hr == 0 && v.vt == 31) ? Marshal.PtrToStringUni(v.p) : ("hr=" + hr + " vt=" + v.vt);
                Marshal.ReleaseComObject(ps);
                return r;
            }
            catch (Exception ex) { return "err " + ex.Message; }
        }
        static void SetStr(IPropertyStore ps, Guid fmt, uint pid, string v)
        {
            PropertyKey k = new PropertyKey(); k.fmtid = fmt; k.pid = pid;
            PropVariant pv = new PropVariant(); pv.vt = 31; pv.p = Marshal.StringToCoTaskMemUni(v);
            try { ps.SetValue(ref k, ref pv); } finally { Marshal.FreeCoTaskMem(pv.p); }
        }

        // ---- single-click open support
        public static bool DragStarted;
        // "namehit" / "pathhit" when the mouse is on the name or path text of a row, else null
        public static string HitTag(object src)
        {
            DependencyObject d = src as DependencyObject;
            while (d != null && !(d is ListBoxItem))
            {
                FrameworkElement fe = d as FrameworkElement;
                if (fe != null && (("namehit".Equals(fe.Tag)) || ("pathhit".Equals(fe.Tag)))) return (string)fe.Tag;
                d = (d is Visual) ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d);
            }
            return null;
        }

        // Same app id on the desktop shortcut, so a pinned shortcut and the running window are one taskbar button.
        public static bool SetLinkAppId(string lnk, string appId)
        {
            try
            {
                object o = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
                System.Runtime.InteropServices.ComTypes.IPersistFile pf = (System.Runtime.InteropServices.ComTypes.IPersistFile)o;
                pf.Load(lnk, 2);
                IPropertyStore ps = (IPropertyStore)o;
                SetStr(ps, new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5, appId);
                ps.Commit();
                pf.Save(lnk, true);
                Marshal.ReleaseComObject(o);
                return true;
            }
            catch (Exception) { return false; }
        }

        // Selects the file in Explorer on a background thread.
        public static OpenJob ShowInFolderAsync(string path)
        {
            OpenJob j = new OpenJob();
            Thread t = new Thread(delegate ()
            {
                try
                {
                    if (!File.Exists(path) && !Directory.Exists(path)) j.Error = "Not found - it was moved or deleted after the last index update.";
                    else Process.Start("explorer.exe", "/select,\"" + path + "\"");
                }
                catch (Exception ex) { j.Error = "Could not open folder: " + ex.Message; }
                j.Done = true;
            });
            t.SetApartmentState(ApartmentState.STA);
            t.IsBackground = true;
            t.Start();
            return j;
        }

        // Opens on a background STA thread so the window never freezes while a NAS file is being opened.
        public static OpenJob OpenAsync(string path, bool dir)
        {
            OpenJob j = new OpenJob();
            Thread t = new Thread(delegate ()
            {
                try
                {
                    if (dir)
                    {
                        if (!Directory.Exists(path)) j.Error = "Folder not found - it was moved or deleted after the last index update.";
                        else Process.Start("explorer.exe", "\"" + path + "\"");
                    }
                    else if (!File.Exists(path)) j.Error = "File not found - it was moved or deleted after the last index update.";
                    else
                    {
                        try
                        {
                            ProcessStartInfo psi = new ProcessStartInfo(path);
                            psi.UseShellExecute = true;
                            Process.Start(psi);
                        }
                        catch (System.ComponentModel.Win32Exception)
                        {
                            Process.Start("rundll32.exe", "shell32.dll,OpenAs_RunDLL " + path);
                        }
                    }
                }
                catch (Exception ex) { j.Error = "Could not open: " + ex.Message; }
                j.Done = true;
            });
            t.SetApartmentState(ApartmentState.STA);
            t.IsBackground = true;
            t.Start();
            return j;
        }

        public static SolidColorBrush B(string hex)
        {
            SolidColorBrush b = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
            b.Freeze();
            return b;
        }
        public static readonly SolidColorBrush HlBrush = B("#FDE68A");
        public static readonly SolidColorBrush Ink = B("#0F172A");
        public static readonly SolidColorBrush Muted = B("#5B6B82");
        public static readonly SolidColorBrush Faint = B("#94A3B8");

        public static void SetAppId(string id) { try { SetCurrentProcessExplicitAppUserModelID(id); } catch (Exception) { } }

        public static void Highlight(TextBlock tb, string s, bool on)
        {
            if (!on || Terms.Length == 0 || string.IsNullOrEmpty(s)) { tb.Text = s; return; }
            bool[] mark = null;
            foreach (string t in Terms)
            {
                if (t.Length == 0) continue;
                int i = 0;
                while ((i = Matcher.Find(s, i, t)) >= 0)
                {
                    if (mark == null) mark = new bool[s.Length];
                    for (int k = i; k < i + t.Length; k++) mark[k] = true;
                    i += t.Length;
                }
            }
            if (mark == null) { tb.Text = s; return; }
            tb.Inlines.Clear();
            int pos = 0;
            while (pos < s.Length)
            {
                bool m = mark[pos];
                int end = pos;
                while (end < s.Length && mark[end] == m) end++;
                Run r = new Run(s.Substring(pos, end - pos));
                if (m) { r.Background = HlBrush; r.Foreground = Ink; }
                tb.Inlines.Add(r);
                pos = end;
            }
        }

        // Real Windows icons + type names, looked up by extension only (no network access), cached.
        static readonly Dictionary<string, ImageSource> icons = new Dictionary<string, ImageSource>(StringComparer.OrdinalIgnoreCase);
        static readonly Dictionary<string, string> types = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        static string Key(FileItem it) { return it.IsDir ? "\\dir" : (it.ExtPos < 0 ? "\\none" : it.FullName.Substring(it.ExtPos)); }

        static void Load(string key, bool dir)
        {
            SHFILEINFO fi = new SHFILEINFO();
            string probe = dir ? "folder" : (key == "\\none" ? "file" : "file." + key);
            uint attr = dir ? 0x10u : 0x80u;
            ImageSource img = null; string tn = null;
            try
            {
                IntPtr r = SHGetFileInfo(probe, attr, ref fi, (uint)Marshal.SizeOf(typeof(SHFILEINFO)), 0x100u | 0x1u | 0x10u | 0x400u);
                if (r != IntPtr.Zero && fi.hIcon != IntPtr.Zero)
                {
                    try
                    {
                        BitmapSource bs = Imaging.CreateBitmapSourceFromHIcon(fi.hIcon, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                        bs.Freeze(); img = bs;
                    }
                    finally { DestroyIcon(fi.hIcon); }
                }
                tn = fi.szTypeName;
            }
            catch (Exception) { }
            if (string.IsNullOrEmpty(tn)) tn = dir ? "File folder" : (key == "\\none" ? "File" : key.ToUpperInvariant() + " File");
            icons[key] = img; types[key] = tn;
        }

        public static ImageSource IconFor(FileItem it)
        {
            string k = Key(it); ImageSource s;
            if (!icons.TryGetValue(k, out s)) { Load(k, it.IsDir); s = icons[k]; }
            return s;
        }

        // extensions shown as picture thumbnails in the grid
        static readonly HashSet<string> imgExt = new HashSet<string>(new string[] {
            "jpg","jpeg","jpe","jfif","png","gif","bmp","dib","tif","tiff","webp","heic","heif","ico","svg",
            "cr2","cr3","nef","arw","dng","orf","rw2","raw","psd" }, StringComparer.OrdinalIgnoreCase);
        public static bool IsImage(FileItem it)
        {
            if (it.IsDir || it.ExtPos < 0) return false;
            return imgExt.Contains(it.FullName.Substring(it.ExtPos));
        }
        public static string TypeFor(FileItem it)
        {
            string k = Key(it); string s;
            if (!types.TryGetValue(k, out s)) { Load(k, it.IsDir); s = types[k]; }
            return s;
        }

        public static string FormatSize(long n)
        {
            if (n < 0) return "";
            if (n < 1024) return n.ToString("N0") + " B";
            if (n < 1048576) return (n / 1024.0).ToString("N0") + " KB";
            if (n < 1073741824L) return (n / 1048576.0).ToString("N1") + " MB";
            return (n / 1073741824.0).ToString("N2") + " GB";
        }

        public static void ShowProperties(string path)
        {
            SHELLEXECUTEINFO i = new SHELLEXECUTEINFO();
            i.cbSize = Marshal.SizeOf(typeof(SHELLEXECUTEINFO));
            i.lpVerb = "properties"; i.lpFile = path; i.nShow = 5; i.fMask = 0x0000000C;
            ShellExecuteEx(ref i);
        }

        public static Tile FindTile(object o)
        {
            DependencyObject d = o as DependencyObject;
            while (d != null)
            {
                Tile t = d as Tile;
                if (t != null) return t;
                if (d is Visual || d is System.Windows.Media.Media3D.Visual3D) d = VisualTreeHelper.GetParent(d);
                else d = LogicalTreeHelper.GetParent(d);
            }
            return null;
        }

        public static ScrollViewer FindScroller(DependencyObject d)
        {
            if (d == null) return null;
            ScrollViewer sv = d as ScrollViewer;
            if (sv != null) return sv;
            int n = VisualTreeHelper.GetChildrenCount(d);
            for (int i = 0; i < n; i++)
            {
                sv = FindScroller(VisualTreeHelper.GetChild(d, i));
                if (sv != null) return sv;
            }
            return null;
        }

        public static ListBoxItem FindItem(object o)
        {
            DependencyObject d = o as DependencyObject;
            while (d != null)
            {
                ListBoxItem li = d as ListBoxItem;
                if (li != null) return li;
                if (d is Visual || d is System.Windows.Media.Media3D.Visual3D) d = VisualTreeHelper.GetParent(d);
                else d = LogicalTreeHelper.GetParent(d);
            }
            return null;
        }

        // Drag selected rows out to Explorer, Outlook, etc. (always a copy, never a move).
        public static void EnableDrag(ListView lv)
        {
            Point start = new Point();
            bool armed = false;
            lv.PreviewMouseLeftButtonDown += delegate (object s, MouseButtonEventArgs e)
            {
                DragStarted = false;
                armed = FindItem(e.OriginalSource) != null;
                start = e.GetPosition(lv);
            };
            lv.PreviewMouseMove += delegate (object s, MouseEventArgs e)
            {
                if (!armed || e.LeftButton != MouseButtonState.Pressed) return;
                Point p = e.GetPosition(lv);
                if (Math.Abs(p.X - start.X) < SystemParameters.MinimumHorizontalDragDistance * 2 &&
                    Math.Abs(p.Y - start.Y) < SystemParameters.MinimumVerticalDragDistance * 2) return;
                armed = false;
                DragStarted = true;
                List<string> files = new List<string>();
                foreach (object o in lv.SelectedItems) { Hit h = o as Hit; if (h != null) files.Add(h.It.FullName); }
                if (files.Count == 0) return;
                try { DragDrop.DoDragDrop(lv, new DataObject(DataFormats.FileDrop, files.ToArray()), DragDropEffects.Copy); }
                catch (Exception) { }
            };
        }

        public static void AnimMargin(FrameworkElement el, double top, int ms)
        {
            ThicknessAnimation a = new ThicknessAnimation(new Thickness(0, top, 0, 0), TimeSpan.FromMilliseconds(ms));
            a.EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut };
            el.BeginAnimation(FrameworkElement.MarginProperty, a);
        }
        public static void AnimFont(TextBlock tb, double size, int ms)
        {
            DoubleAnimation a = new DoubleAnimation(size, TimeSpan.FromMilliseconds(ms));
            a.EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut };
            tb.BeginAnimation(TextBlock.FontSizeProperty, a);
        }
        public static void FadeIn(UIElement el, int ms)
        {
            el.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(ms)));
        }
    }

    // Magnifying-lens app icon, drawn in code so no extra file has to be shipped.
    public static class AppIcon
    {
        static BitmapSource Render(int px)
        {
            DrawingVisual dv = new DrawingVisual();
            using (DrawingContext dc = dv.RenderOpen())
            {
                double s = px / 256.0;
                dc.PushTransform(new ScaleTransform(s, s));
                LinearGradientBrush bg = new LinearGradientBrush(Color.FromRgb(0x1D, 0x4E, 0xD8), Color.FromRgb(0x0E, 0xA5, 0xE9), new Point(0, 0), new Point(1, 1));
                dc.DrawRoundedRectangle(bg, null, new Rect(6, 6, 244, 244), 58, 58);
                SolidColorBrush glass = new SolidColorBrush(Color.FromArgb(70, 255, 255, 255));
                Pen ring = new Pen(Brushes.White, 24);
                dc.DrawEllipse(glass, ring, new Point(110, 108), 60, 60);
                Pen handle = new Pen(Brushes.White, 34);
                handle.StartLineCap = PenLineCap.Round; handle.EndLineCap = PenLineCap.Round;
                dc.DrawLine(handle, new Point(160, 158), new Point(204, 202));
                Pen glint = new Pen(new SolidColorBrush(Color.FromArgb(230, 255, 255, 255)), 11);
                glint.StartLineCap = PenLineCap.Round; glint.EndLineCap = PenLineCap.Round;
                StreamGeometry g = new StreamGeometry();
                using (StreamGeometryContext c = g.Open())
                {
                    c.BeginFigure(new Point(76, 108), false, false);
                    c.ArcTo(new Point(110, 74), new Size(34, 34), 0, false, SweepDirection.Clockwise, true, true);
                }
                dc.DrawGeometry(null, glint, g);
                dc.Pop();
            }
            RenderTargetBitmap rtb = new RenderTargetBitmap(px, px, 96, 96, PixelFormats.Pbgra32);
            rtb.Render(dv);
            rtb.Freeze();
            return rtb;
        }

        public static void WriteIco(string path)
        {
            int[] sizes = { 16, 20, 24, 32, 40, 48, 64, 128, 256 };
            List<byte[]> data = new List<byte[]>();
            foreach (int px in sizes)
            {
                PngBitmapEncoder enc = new PngBitmapEncoder();
                enc.Frames.Add(BitmapFrame.Create(Render(px)));
                using (MemoryStream ms = new MemoryStream()) { enc.Save(ms); data.Add(ms.ToArray()); }
            }
            using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write))
            using (BinaryWriter bw = new BinaryWriter(fs))
            {
                bw.Write((short)0); bw.Write((short)1); bw.Write((short)sizes.Length);
                int offset = 6 + 16 * sizes.Length;
                for (int i = 0; i < sizes.Length; i++)
                {
                    byte d = (byte)(sizes[i] >= 256 ? 0 : sizes[i]);
                    bw.Write(d); bw.Write(d); bw.Write((byte)0); bw.Write((byte)0);
                    bw.Write((short)1); bw.Write((short)32);
                    bw.Write(data[i].Length); bw.Write(offset);
                    offset += data[i].Length;
                }
                foreach (byte[] b in data) bw.Write(b);
            }
        }
    }

    // ---------------------------------------------------------------- table cells (virtualized, recycled)
    // One image tile: thumbnail on top, file name under it. Loads its own thumbnail lazily.
    public class Tile : Border
    {
        public static readonly DependencyProperty ItemProperty =
            DependencyProperty.Register("Item", typeof(object), typeof(Tile), new PropertyMetadata(null, OnItem));
        public object Item { get { return GetValue(ItemProperty); } set { SetValue(ItemProperty, value); } }

        public const int Thumb = 132;
        readonly Image img;
        readonly TextBlock name;
        readonly Border pic;
        ThumbJob job;
        string loadedPath;

        public Tile()
        {
            HorizontalAlignment = HorizontalAlignment.Stretch;
            MinWidth = Thumb + 20;
            Margin = new Thickness(6);
            Background = System.Windows.Media.Brushes.Transparent;
            BorderThickness = new Thickness(1);
            BorderBrush = System.Windows.Media.Brushes.Transparent;
            CornerRadius = new CornerRadius(10);
            Padding = new Thickness(6, 6, 6, 8);
            Cursor = Cursors.Hand;

            StackPanel sp = new StackPanel();
            pic = new Border();
            pic.Width = Thumb; pic.Height = Thumb;
            pic.Background = Ui.B("#F1F5F9");
            pic.CornerRadius = new CornerRadius(8);
            pic.SnapsToDevicePixels = true;
            img = new Image();
            img.Stretch = Stretch.Uniform;
            img.HorizontalAlignment = HorizontalAlignment.Center;
            img.VerticalAlignment = VerticalAlignment.Center;
            RenderOptions.SetBitmapScalingMode(img, BitmapScalingMode.HighQuality);
            pic.Child = img;
            sp.Children.Add(pic);

            name = new TextBlock();
            name.TextAlignment = TextAlignment.Center;
            name.TextTrimming = TextTrimming.CharacterEllipsis;
            name.MaxHeight = 32;
            name.TextWrapping = TextWrapping.Wrap;
            name.FontSize = 11.5;
            name.Foreground = Ui.Ink;
            name.Margin = new Thickness(0, 6, 0, 0);
            sp.Children.Add(name);
            Child = sp;
            Unloaded += delegate { Stop(); };
            MouseEnter += delegate { Background = Ui.B("#EFF4FC"); };
            MouseLeave += delegate { Background = System.Windows.Media.Brushes.Transparent; };
        }
        public Hit HitItem { get { return Item as Hit; } }

        static void OnItem(DependencyObject d, DependencyPropertyChangedEventArgs e)
        {
            ((Tile)d).Render(e.NewValue as Hit);
        }

        void Render(Hit h)
        {
            Stop();
            if (h == null) { img.Source = null; name.Text = ""; ToolTip = null; loadedPath = null; return; }
            FileItem it = h.It;
            name.Text = it.Name;
            string nl2 = Environment.NewLine;
            ToolTip = it.Name + nl2 + it.FullName + nl2 + (it.T == DateTime.MinValue ? "" : it.T.ToString("dd-MMM-yyyy  hh:mm tt", CultureInfo.InvariantCulture));
            loadedPath = it.FullName;
            ImageSource c = Thumbs.Cached(it.FullName);
            if (c != null) { img.Source = c; img.Stretch = Stretch.Uniform; return; }
            img.Source = Ui.IconFor(it);           // type icon first, replaced by the real thumbnail when ready
            img.Stretch = Stretch.None;
            job = Thumbs.Request(it.FullName, Thumb, Dispatcher, Done);
        }

        void Done(ThumbJob j)
        {
            if (j != job) return;
            job = null;
            if (j.Image == null) return;
            Thumbs.Remember(j.Path, j.Image);
            if (j.Path != loadedPath) return;
            img.Source = j.Image;
            img.Stretch = Stretch.Uniform;
        }

        void Stop()
        {
            if (job != null) { job.Cancel = true; job = null; }
        }
    }

    public class TileRow : System.Windows.Controls.Primitives.UniformGrid
    {
        public static readonly DependencyProperty ItemsProperty =
            DependencyProperty.Register("Items", typeof(object), typeof(TileRow), new PropertyMetadata(null, OnItems));
        public object Items { get { return GetValue(ItemsProperty); } set { SetValue(ItemsProperty, value); } }

        public static int Cols = 6;        // set from the window width
        public TileRow() { Rows = 1; Columns = Cols; }

        static void OnItems(DependencyObject d, DependencyPropertyChangedEventArgs e)
        {
            TileRow r = (TileRow)d;
            Hit[] hs = e.NewValue as Hit[];
            int n = hs == null ? 0 : hs.Length;
            r.Columns = Cols;
            while (r.Children.Count < n) r.Children.Add(new Tile());
            for (int i = 0; i < r.Children.Count; i++)
            {
                Tile t = (Tile)r.Children[i];
                if (i < n) { t.Item = hs[i]; t.Visibility = Visibility.Visible; }
                else { t.Item = null; t.Visibility = Visibility.Collapsed; }
            }
        }
    }

    public class Cell : Border
    {
        public static readonly DependencyProperty ItemProperty =
            DependencyProperty.Register("Item", typeof(object), typeof(Cell), new PropertyMetadata(null, OnItem));
        public object Item { get { return GetValue(ItemProperty); } set { SetValue(ItemProperty, value); } }

        protected readonly TextBlock Txt;
        public Cell()
        {
            Txt = new TextBlock();
            Txt.TextTrimming = TextTrimming.CharacterEllipsis;
            Txt.VerticalAlignment = VerticalAlignment.Center;
            Txt.FontSize = 12;
            Txt.Foreground = Ui.Muted;
            Child = Txt;
            Padding = new Thickness(2, 0, 2, 0);
        }
        static void OnItem(DependencyObject d, DependencyPropertyChangedEventArgs e)
        {
            Cell c = (Cell)d;
            Hit h = e.NewValue as Hit;
            if (h == null) { c.Txt.Text = ""; c.ToolTip = null; return; }
            c.Render(h.It);
        }
        protected virtual void Render(FileItem it) { }
    }

    public class NameCell : Cell
    {
        readonly Image icon;
        public NameCell()
        {
            Txt.Foreground = Ui.Ink;
            icon = new Image();
            icon.Width = 16; icon.Height = 16;
            icon.Margin = new Thickness(0, 0, 8, 0);
            icon.VerticalAlignment = VerticalAlignment.Center;
            RenderOptions.SetBitmapScalingMode(icon, BitmapScalingMode.HighQuality);
            DockPanel dp = new DockPanel();
            dp.HorizontalAlignment = HorizontalAlignment.Left;
            dp.Background = Brushes.Transparent;
            dp.Cursor = Cursors.Hand;
            dp.Tag = "namehit";
            dp.ToolTip = "Click to open";
            DockPanel.SetDock(icon, Dock.Left);
            Child = null;
            dp.Children.Add(icon);
            dp.Children.Add(Txt);
            Child = dp;
        }
        protected override void Render(FileItem it)
        {
            icon.Source = Ui.IconFor(it);
            Ui.Highlight(Txt, it.Name, true);
        }
    }
    public class FolderCell : Cell
    {
        public FolderCell()
        {
            Txt.HorizontalAlignment = HorizontalAlignment.Left;
            Txt.Background = Brushes.Transparent;
            Txt.Cursor = Cursors.Hand;
            Txt.Tag = "pathhit";
            Txt.ToolTip = "Click to open this folder";
        }
        protected override void Render(FileItem it) { Ui.Highlight(Txt, it.Folder, Ui.HlPath); }
    }
    public class PathCell : Cell
    {
        protected override void Render(FileItem it) { Ui.Highlight(Txt, it.FullName, Ui.HlPath); ToolTip = it.FullName; }
    }
    public class SizeCell : Cell
    {
        public SizeCell() { Txt.TextAlignment = TextAlignment.Right; }
        protected override void Render(FileItem it) { Txt.Text = it.IsDir ? "" : Ui.FormatSize(it.Size); }
    }
    public class DateCell : Cell
    {
        protected override void Render(FileItem it)
        {
            Txt.Text = it.T == DateTime.MinValue ? "" : it.T.ToString("dd-MM-yyyy  HH:mm", CultureInfo.InvariantCulture);
        }
    }
    public class TypeCell : Cell
    {
        protected override void Render(FileItem it) { Txt.Text = Ui.TypeFor(it); }
    }

    // Column set: users can resize (drag the header edge), reorder (drag a header), hide/show and sort.
    public static class Cols
    {
        public static readonly string[] Keys = { "name", "path", "size", "modified", "type", "full" };
        public static readonly string[] Titles = { "Name", "Path", "Size", "Date modified", "Type", "Full path" };
        static readonly double[] DefW = { 320, 420, 90, 140, 150, 520 };
        static readonly bool[] DefVis = { true, true, true, true, true, false };
        static readonly Type[] CellT = { typeof(NameCell), typeof(FolderCell), typeof(SizeCell), typeof(DateCell), typeof(TypeCell), typeof(PathCell) };
        public static GridViewColumn[] All;
        static List<int> Order = new List<int>();

        static void Init()
        {
            if (All != null) return;
            All = new GridViewColumn[Keys.Length];
            for (int i = 0; i < Keys.Length; i++)
            {
                FrameworkElementFactory f = new FrameworkElementFactory(CellT[i]);
                f.SetBinding(Cell.ItemProperty, new Binding());
                DataTemplate dt = new DataTemplate();
                dt.VisualTree = f;
                dt.Seal();
                GridViewColumn c = new GridViewColumn();
                c.Header = Titles[i];
                c.CellTemplate = dt;
                All[i] = c;
            }
        }

        public static int IndexOf(GridViewColumn c) { return All == null ? -1 : Array.IndexOf(All, c); }

        public static void Build(GridView gv, string spec)
        {
            Init();
            gv.Columns.Clear();
            List<int> order = new List<int>();
            bool[] vis = (bool[])DefVis.Clone();
            double[] wid = (double[])DefW.Clone();
            if (!string.IsNullOrEmpty(spec))
            {
                foreach (string part in spec.Split(','))
                {
                    string[] a = part.Split(':');
                    int i = Array.IndexOf(Keys, a[0]);
                    if (i < 0 || order.Contains(i)) continue;
                    order.Add(i);
                    double w;
                    if (a.Length > 1 && double.TryParse(a[1], NumberStyles.Float, CultureInfo.InvariantCulture, out w) && w >= 30 && w < 4000) wid[i] = w;
                    if (a.Length > 2) vis[i] = a[2] != "0";
                }
            }
            for (int i = 0; i < Keys.Length; i++) if (!order.Contains(i)) order.Add(i);
            vis[0] = true;
            Order = order;
            foreach (int i in order) { All[i].Width = wid[i]; if (vis[i]) gv.Columns.Add(All[i]); }
        }

        static string W(GridViewColumn c, int i)
        {
            double w = c.ActualWidth;
            if (double.IsNaN(w) || w <= 0) w = c.Width;
            if (double.IsNaN(w) || w <= 0) w = DefW[i];
            return Math.Round(w).ToString(CultureInfo.InvariantCulture);
        }

        public static string Spec(GridView gv)
        {
            if (All == null) return "";
            List<string> parts = new List<string>();
            List<int> seen = new List<int>();
            foreach (GridViewColumn c in gv.Columns)
            {
                int i = IndexOf(c); if (i < 0) continue;
                seen.Add(i);
                parts.Add(Keys[i] + ":" + W(c, i) + ":1");
            }
            foreach (int i in Order) if (!seen.Contains(i)) parts.Add(Keys[i] + ":" + W(All[i], i) + ":0");
            return string.Join(",", parts.ToArray());
        }

        public static bool IsVisible(GridView gv, int i) { return gv.Columns.Contains(All[i]); }

        public static void SetVisible(GridView gv, int i, bool vis)
        {
            if (i <= 0 || i >= All.Length) return;
            int cur = gv.Columns.IndexOf(All[i]);
            if (!vis) { if (cur >= 0) gv.Columns.RemoveAt(cur); return; }
            if (cur >= 0) return;
            int pos = 0;
            for (int k = 0; k < gv.Columns.Count; k++) if (IndexOf(gv.Columns[k]) < i) pos = k + 1;
            gv.Columns.Insert(pos, All[i]);
        }

        public static void AutoFit(GridView gv)
        {
            foreach (GridViewColumn c in gv.Columns)
            {
                if (double.IsNaN(c.Width)) c.Width = c.ActualWidth;
                c.Width = double.NaN;
            }
            gv.Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(delegate
            {
                foreach (GridViewColumn c in gv.Columns) c.Width = Math.Min(Math.Max(c.ActualWidth, 60), 800);
            }));
        }

    }
}
'@

Add-Type -TypeDefinition $csharp -ReferencedAssemblies System, PresentationFramework, PresentationCore, WindowsBase, System.Xaml -IgnoreWarnings

[US.Ui]::SetAppId($AppId)
[US.Ui]::SetupMenus()

# ---------------- paths & settings ----------------
$docs     = [Environment]::GetFolderPath('MyDocuments')
$cfgDir   = Join-Path $env:APPDATA 'UniversalSearch'
$cfgPath  = Join-Path $cfgDir 'settings.cfg'
$icoPath  = Join-Path $cfgDir 'UniversalSearch.ico'
$csvPath  = Join-Path $docs 'index.csv'          # old index format - still readable
# Local copies of the index (fast searching without reading the NAS every time)
$dataDir     = Join-Path $env:LOCALAPPDATA 'UniversalSearch'
$cacheCommon = Join-Path $dataDir 'common.usx'   # copy of the shared common-drive index
$pcIndexPath = Join-Path $dataDir 'thispc.usx'   # "This PC" index - never shared
# The shared index lives next to this app (e.g. W:\UniversalSearch) unless the admin picks another folder.
$appDir = if ($SelfPath) { Split-Path -Parent $SelfPath } else { $docs }
$cfg = @{ index = ''; drive = ''; depth = ''; threads = '16'; cols2 = ''; zoom = '1'; scope = 'path'; idxdepth = ''; shared = ''; nasstamp = ''; pcdrive = ''; pcskip = '1'; pcdocs = '1' }
if (Test-Path -LiteralPath $cfgPath) {
    foreach ($l in (Get-Content -LiteralPath $cfgPath)) {
        $p = $l.IndexOf('=')
        if ($p -gt 0) { $cfg[$l.Substring(0, $p).Trim()] = $l.Substring($p + 1) }
    }
}
function Test-LocalPath([string]$p) {
    if (-not $p -or $p.StartsWith('\\')) { return $false }
    try { return ((New-Object System.IO.DriveInfo ($p.Substring(0, 1))).DriveType -eq [System.IO.DriveType]::Fixed) } catch { return $false }
}
function Get-DriveRoot([string]$p) {
    $p = ([string]$p).Trim()
    if ($p -match '^([A-Za-z]:)') { return $matches[1] + '\' }
    if ($p -match '^(\\\\[^\\]+\\[^\\]+)') { return $matches[1] + '\' }
    return $null
}
# started from the common drive (the normal set-up)? then that drive is the common drive
$appOnNetwork = [bool]$SelfPath -and -not (Test-LocalPath $appDir)
if (-not $cfg['drive']) { $cfg['drive'] = $(if ($appOnNetwork -and (Get-DriveRoot $appDir)) { Get-DriveRoot $appDir } else { 'W:\' }) }
try {
    if (-not (Test-Path -LiteralPath $cfgDir)) { [void](New-Item -ItemType Directory -Path $cfgDir -Force) }
    if (-not (Test-Path -LiteralPath $dataDir)) { [void](New-Item -ItemType Directory -Path $dataDir -Force) }
    if (-not (Test-Path -LiteralPath $icoPath)) { [US.AppIcon]::WriteIco($icoPath) }
} catch { }

# ---------------- window ----------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Universal Search System" Width="1240" Height="780" MinWidth="940" MinHeight="560"
        Background="#F3F6FB" FontFamily="Segoe UI" WindowStartupLocation="CenterScreen" UseLayoutRounding="True">
  <Window.Resources>

    <!-- slim modern scrollbars -->
    <Style x:Key="SbThumb" TargetType="Thumb">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="t" CornerRadius="4" Background="#C5CFDD"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Background" Value="#94A3B8"/></Trigger>
              <Trigger Property="IsDragging" Value="True"><Setter TargetName="t" Property="Background" Value="#64748B"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SbPage" TargetType="RepeatButton">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Width" Value="12"/>
      <Setter Property="MinWidth" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Border Background="Transparent" Padding="3,4">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource SbPage}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource SbPage}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource SbThumb}" MinHeight="36"/></Track.Thumb>
              </Track>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="12"/>
          <Setter Property="MinHeight" Value="12"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Border Background="Transparent" Padding="4,3">
                  <Track x:Name="PART_Track" IsDirectionReversed="False">
                    <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource SbPage}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
                    <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource SbPage}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
                    <Track.Thumb><Thumb Style="{StaticResource SbThumb}" MinWidth="36"/></Track.Thumb>
                  </Track>
                </Border>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- rounded popup menus -->
    <Style x:Key="MenuStyle" TargetType="ContextMenu">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="HasDropShadow" Value="False"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ContextMenu">
            <Border Margin="6,4,14,14" Background="White" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="12" Padding="5">
              <Border.Effect><DropShadowEffect BlurRadius="20" ShadowDepth="4" Opacity="0.16" Color="#0F172A"/></Border.Effect>
              <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="MiStyle" TargetType="MenuItem">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Foreground" Value="#1E293B"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="MenuItem">
            <Border x:Name="bd" CornerRadius="8" Padding="8,6,16,6" Background="Transparent" MinWidth="190">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="26"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <ContentPresenter x:Name="ico" ContentSource="Icon" VerticalAlignment="Center" HorizontalAlignment="Left"/>
                <TextBlock x:Name="chk" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="#2563EB" VerticalAlignment="Center" Visibility="Collapsed"/>
                <ContentPresenter Grid.Column="1" ContentSource="Header" RecognizesAccessKey="True" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="2" Text="{TemplateBinding InputGestureText}" Foreground="#94A3B8" FontSize="11.5" Margin="28,0,0,0" VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="bd" Property="Background" Value="#EEF4FF"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="chk" Property="Visibility" Value="Visible"/>
                <Setter TargetName="bd" Property="Background" Value="#E8F0FF"/>
                <Setter Property="Foreground" Value="#1D4ED8"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="#A0AEC0"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SepStyle" TargetType="Separator">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Separator"><Border Height="1" Background="#E8EDF4" Margin="10,4"/></ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- results table -->
    <Style x:Key="RowStyle" TargetType="ListViewItem">
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="MinHeight" Value="25"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListViewItem">
            <Border x:Name="bd" Background="{TemplateBinding Background}" SnapsToDevicePixels="True">
              <GridViewRowPresenter Columns="{TemplateBinding GridView.ColumnCollection}" Content="{TemplateBinding Content}" VerticalAlignment="Center" Margin="0,1"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#E6F0FF"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="bd" Property="Background" Value="#CCE0FF"/></Trigger>
              <MultiTrigger>
                <MultiTrigger.Conditions>
                  <Condition Property="IsSelected" Value="True"/>
                  <Condition Property="Selector.IsSelectionActive" Value="False"/>
                </MultiTrigger.Conditions>
                <Setter TargetName="bd" Property="Background" Value="#DCE6F4"/>
              </MultiTrigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="ItemsControl.AlternationIndex" Value="1"><Setter Property="Background" Value="#F3F5F9"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="HeadStyle" TargetType="GridViewColumnHeader">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Foreground" Value="#475569"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="GridViewColumnHeader">
            <Grid>
              <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="#E2E8F0" BorderThickness="0,0,0,1" Padding="9,0,8,0">
                <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" RecognizesAccessKey="False"/>
              </Border>
              <Thumb x:Name="PART_HeaderGripper" HorizontalAlignment="Right" Width="11" Margin="0,0,-5,0" Cursor="SizeWE">
                <Thumb.Template>
                  <ControlTemplate TargetType="Thumb">
                    <Border Background="Transparent">
                      <Rectangle x:Name="ln" Width="1" Fill="#DCE3EE" Margin="0,7"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ln" Property="Fill" Value="#2563EB"/><Setter TargetName="ln" Property="Width" Value="2"/><Setter TargetName="ln" Property="Margin" Value="0,3"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </Thumb.Template>
              </Thumb>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#F1F5FB"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Background" Value="#E6EEF9"/></Trigger>
              <Trigger Property="Role" Value="Padding"><Setter TargetName="PART_HeaderGripper" Property="Visibility" Value="Collapsed"/><Setter Property="Cursor" Value="Arrow"/></Trigger>
              <Trigger Property="Role" Value="Floating"><Setter TargetName="bd" Property="Opacity" Value="0.8"/><Setter TargetName="PART_HeaderGripper" Property="Visibility" Value="Collapsed"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- buttons, chips, pills -->
    <Style x:Key="Accent" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="#2563EB"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.88"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Ghost" TargetType="Button">
      <Setter Property="Foreground" Value="#1E3A8A"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#CBD5E1"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#EEF4FF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ChipBtn" TargetType="Button" BasedOn="{StaticResource Ghost}">
      <Setter Property="Foreground" Value="#475569"/>
      <Setter Property="Padding" Value="14,5"/>
      <Setter Property="Margin" Value="3,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="o" Background="{TemplateBinding BorderBrush}" CornerRadius="15" Padding="1">
              <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="14" Padding="{TemplateBinding Padding}">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="o" Property="Background" Value="#93C5FD"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="#475569"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="3,0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="o" Background="#CBD5E1" CornerRadius="15" Padding="1">
              <Border x:Name="b" Background="White" CornerRadius="14" Padding="14,4">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="o" Property="Background" Value="#93C5FD"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="#DBEAFE"/>
                <Setter TargetName="o" Property="Background" Value="#2563EB"/>
                <Setter Property="Foreground" Value="#1E40AF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ViewTab" TargetType="ToggleButton">
      <Setter Property="Foreground" Value="#64748B"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="b" Background="Transparent" CornerRadius="7" Padding="10,5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#1E40AF"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="White"/>
                <Setter TargetName="b" Property="Effect"><Setter.Value><DropShadowEffect BlurRadius="6" ShadowDepth="1" Opacity="0.16" Color="#0F172A"/></Setter.Value></Setter>
                <Setter Property="Foreground" Value="#1D4ED8"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="TChip" TargetType="ToggleButton">
      <Setter Property="Foreground" Value="#475569"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="3,0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="o" Background="#CBD5E1" CornerRadius="15" Padding="1">
              <Border x:Name="b" Background="White" CornerRadius="14" Padding="13,4">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="o" Property="Background" Value="#93C5FD"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="#DBEAFE"/>
                <Setter TargetName="o" Property="Background" Value="#2563EB"/>
                <Setter Property="Foreground" Value="#1E40AF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Round" TargetType="Button">
      <Setter Property="Foreground" Value="#1E3A8A"/>
      <Setter Property="Width" Value="32"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="o" Background="#CBD5E1" CornerRadius="16" Padding="1">
              <Border x:Name="b" Background="White" CornerRadius="15">
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="o" Property="Background" Value="#93C5FD"/>
                <Setter TargetName="b" Property="Background" Value="#EEF4FF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- text that disappears when empty -->
    <Style x:Key="Msg" TargetType="TextBlock">
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Style.Triggers>
        <Trigger Property="Text" Value=""><Setter Property="Visibility" Value="Collapsed"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Pill" TargetType="Border">
      <Setter Property="Background" Value="#E9EFFB"/>
      <Setter Property="CornerRadius" Value="11"/>
      <Setter Property="Padding" Value="10,3"/>
      <Setter Property="Margin" Value="4,0"/>
    </Style>
    <Style x:Key="PillIco" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="#2563EB"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,1,6,0"/>
    </Style>
    <Style x:Key="PillTxt" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Foreground" Value="#1E3A8A"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="4"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="28"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
          <GradientStop Color="#1E40AF" Offset="0"/>
          <GradientStop Color="#38BDF8" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
    </Border>

    <StackPanel x:Name="topPanel" Grid.Row="1" Margin="0,150,0,0">
      <StackPanel x:Name="greetRow" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,0,0,16">
        <TextBlock x:Name="greetIco" FontFamily="Segoe MDL2 Assets" FontSize="15" VerticalAlignment="Center" Margin="0,1,9,0"/>
        <TextBlock x:Name="greetTxt" FontSize="16" FontWeight="SemiBold" Foreground="#475569" VerticalAlignment="Center"/>
        <TextBlock x:Name="greetEmo" FontFamily="Segoe UI Emoji" FontSize="17" VerticalAlignment="Center" Margin="8,0,0,0"/>
      </StackPanel>
      <TextBlock x:Name="title" Text="Universal Search System" FontSize="42" FontWeight="Bold" Foreground="#1E40AF" HorizontalAlignment="Center"/>
      <StackPanel x:Name="heroPills" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,10,0,18">
        <Border Style="{StaticResource Pill}"><StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource PillIco}" Text="&#xE8A5;"/><TextBlock x:Name="hItems" Style="{StaticResource PillTxt}" Text="Loading index..."/></StackPanel></Border>
        <Border Style="{StaticResource Pill}"><StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource PillIco}" Text="&#xE8B7;"/><TextBlock x:Name="hDepth" Style="{StaticResource PillTxt}" Text="Depth -"/></StackPanel></Border>
        <Border Style="{StaticResource Pill}"><StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource PillIco}" Text="&#xE823;"/><TextBlock x:Name="hUpdated" Style="{StaticResource PillTxt}" Text="Last updated -"/></StackPanel></Border>
      </StackPanel>
      <Border MaxWidth="720" Margin="30,0,30,0" Background="White" CornerRadius="26" BorderBrush="#CBD5E1" BorderThickness="1" Padding="18,4,10,4">
        <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="3" Opacity="0.12" Color="#1E3A8A"/></Border.Effect>
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" FontSize="17" Foreground="#2563EB" VerticalAlignment="Center" Margin="0,0,12,0"/>
          <TextBox x:Name="searchBox" Grid.Column="1" FontSize="17" BorderThickness="0" Background="Transparent" Foreground="#0F172A" CaretBrush="#2563EB" VerticalContentAlignment="Center" Padding="0,7"/>
          <TextBlock x:Name="hint" Grid.Column="1" Text="Type file or folder name..." FontSize="17" Foreground="#94A3B8" IsHitTestVisible="False" VerticalAlignment="Center"/>
          <Button x:Name="btnClear" Grid.Column="2" Content="&#xE711;" FontFamily="Segoe MDL2 Assets" FontSize="11" Style="{StaticResource Ghost}" BorderThickness="0" Background="Transparent" Padding="10,8" Visibility="Collapsed" ToolTip="Clear (Esc)"/>
        </Grid>
      </Border>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,12,0,0">
        <ToggleButton x:Name="tScopeAll" Style="{StaticResource TChip}" Content="All"/>
        <ToggleButton x:Name="tName" Style="{StaticResource TChip}" Content="Name only"/>
        <ToggleButton x:Name="tPath" Style="{StaticResource TChip}" Content="Full path"/>
        <Border Width="1" Background="#CBD5E1" Margin="10,4"/>
        <RadioButton x:Name="rbAll" Content="All" GroupName="kind" IsChecked="True"/>
        <RadioButton x:Name="rbFiles" Content="Files" GroupName="kind"/>
        <RadioButton x:Name="rbDirs" Content="Folders" GroupName="kind"/>
        <Border Width="1" Background="#CBD5E1" Margin="10,4"/>
        <ToggleButton x:Name="tTypeAll" Style="{StaticResource TChip}" Content="All"/>
        <ToggleButton x:Name="tPdf" Style="{StaticResource TChip}" Content="PDF" Tag="PDF"/>
        <ToggleButton x:Name="tXls" Style="{StaticResource TChip}" Content="Excel" Tag="Excel"/>
        <ToggleButton x:Name="tDoc" Style="{StaticResource TChip}" Content="Word" Tag="Word"/>
        <ToggleButton x:Name="tImg" Style="{StaticResource TChip}" Content="Images" Tag="Images"/>
      </StackPanel>
      <TextBlock x:Name="tipLbl" HorizontalAlignment="Center" Margin="0,16,0,0" FontSize="12" Foreground="#94A3B8"
                 Text="Tip: press Space twice anywhere to jump back to the search box"/>
    </StackPanel>

    <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,12,20,0" Panel.ZIndex="5">
      <Button x:Name="btnHelp" Style="{StaticResource Round}" Margin="0,0,8,0" ToolTip="Help and tips" VerticalAlignment="Center">
        <TextBlock Text="&#xE946;" FontFamily="Segoe MDL2 Assets" FontSize="14"/>
      </Button>
      <Button x:Name="btnShare" Style="{StaticResource Round}" Margin="0,0,10,0" ToolTip="Take me to another PC" VerticalAlignment="Center">
        <TextBlock Text="&#xE896;" FontFamily="Segoe MDL2 Assets" FontSize="14"/>
      </Button>
      <Button x:Name="btnIdx" Style="{StaticResource Ghost}" Padding="12,6">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="&#xE72C;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center" Margin="0,1,8,0"/>
          <TextBlock Text="Update index" VerticalAlignment="Center"/>
        </StackPanel>
      </Button>
    </StackPanel>

    <Grid x:Name="results" Grid.Row="2" Visibility="Collapsed" Margin="18,10,18,8">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <DockPanel Margin="2,0,2,8">
        <Button x:Name="btnCols" DockPanel.Dock="Right" Style="{StaticResource ChipBtn}" Padding="12,4">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE8A9;" FontFamily="Segoe MDL2 Assets" FontSize="11" VerticalAlignment="Center" Margin="0,1,6,0"/>
            <TextBlock Text="Columns &#x25BE;" VerticalAlignment="Center"/>
          </StackPanel>
        </Button>
        <Border x:Name="viewToggle" DockPanel.Dock="Right" Visibility="Collapsed" Background="#EEF2F7" CornerRadius="9" Padding="2" Margin="0,0,8,0" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <ToggleButton x:Name="tbList" Style="{StaticResource ViewTab}" ToolTip="List view">
              <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8FD;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center" Margin="0,0,5,0"/><TextBlock Text="List" VerticalAlignment="Center"/></StackPanel>
            </ToggleButton>
            <ToggleButton x:Name="tbGrid" Style="{StaticResource ViewTab}" ToolTip="Thumbnail grid">
              <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE80A;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center" Margin="0,0,5,0"/><TextBlock Text="Grid" VerticalAlignment="Center"/></StackPanel>
            </ToggleButton>
          </StackPanel>
        </Border>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" ClipToBounds="True">
          <Border Style="{StaticResource Pill}"><StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource PillIco}" Text="&#xE8A5;"/><TextBlock x:Name="cItems" Style="{StaticResource PillTxt}"/></StackPanel></Border>
          <Border Style="{StaticResource Pill}" Visibility="Collapsed"><StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource PillIco}" Text="&#xE8B7;"/><TextBlock x:Name="cDepth" Style="{StaticResource PillTxt}"/></StackPanel></Border>
          <Border Style="{StaticResource Pill}" Visibility="Collapsed"><StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource PillIco}" Text="&#xE823;"/><TextBlock x:Name="cUpdated" Style="{StaticResource PillTxt}"/></StackPanel></Border>
          <StackPanel x:Name="chipBar" Orientation="Horizontal" Margin="8,0,0,0"/>
        </StackPanel>
      </DockPanel>
      <Border Grid.Row="1" Background="White" CornerRadius="12" BorderBrush="#E2E8F0" BorderThickness="1" Padding="1">
        <Grid>
          <ListView x:Name="list" BorderThickness="0" Background="White" SelectionMode="Extended" AlternationCount="2"
                    ItemContainerStyle="{StaticResource RowStyle}" IsTextSearchEnabled="False"
                    VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling" VirtualizingPanel.ScrollUnit="Item"
                    ScrollViewer.CanContentScroll="True" ScrollViewer.HorizontalScrollBarVisibility="Auto">
            <ListView.View>
              <GridView AllowsColumnReorder="True" ColumnHeaderContainerStyle="{StaticResource HeadStyle}"/>
            </ListView.View>
          </ListView>
          <ListBox x:Name="gridList" Visibility="Collapsed" BorderThickness="0" Background="White" Padding="8,8,0,8"
                   VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling" VirtualizingPanel.ScrollUnit="Pixel"
                   ScrollViewer.CanContentScroll="True" ScrollViewer.HorizontalScrollBarVisibility="Disabled" ScrollViewer.VerticalScrollBarVisibility="Auto">
            <ListBox.ItemContainerStyle>
              <Style TargetType="ListBoxItem">
                <Setter Property="Focusable" Value="False"/>
                <Setter Property="Template">
                  <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem"><ContentPresenter/></ControlTemplate>
                  </Setter.Value>
                </Setter>
              </Style>
            </ListBox.ItemContainerStyle>
          </ListBox>
          <StackPanel x:Name="emptyState" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center">
            <TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" FontSize="34" Foreground="#CBD5E1" HorizontalAlignment="Center"/>
            <TextBlock x:Name="emptyText" FontSize="15" FontWeight="SemiBold" Foreground="#475569" HorizontalAlignment="Center" Margin="0,12,0,4"/>
            <TextBlock x:Name="emptyHint" FontSize="12" Foreground="#94A3B8" HorizontalAlignment="Center"/>
            <Button x:Name="btnResetFilters" Style="{StaticResource Ghost}" HorizontalAlignment="Center" Margin="0,14,0,0" Padding="14,6" Visibility="Collapsed">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE72C;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center" Margin="0,1,8,0"/>
                <TextBlock Text="Reset filters" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
          </StackPanel>
          <Border x:Name="gridMore" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,10"
                  Background="#E60F172A" CornerRadius="12" Padding="12,5" IsHitTestVisible="False">
            <TextBlock x:Name="gridMoreText" Foreground="White" FontSize="11.5"/>
          </Border>
          <Border x:Name="openToast" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,26"
                  Background="#F20F172A" CornerRadius="20" Padding="16,9,20,9" IsHitTestVisible="False">
            <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="3" Opacity="0.3"/></Border.Effect>
            <StackPanel Orientation="Horizontal">
              <Grid Width="18" Height="18" Margin="0,0,10,0">
                <Ellipse Stroke="#334155" StrokeThickness="2.5"/>
                <Ellipse x:Name="spinner" Stroke="#60A5FA" StrokeThickness="2.5" StrokeDashArray="7 30" RenderTransformOrigin="0.5,0.5"/>
              </Grid>
              <TextBlock x:Name="toastText" Foreground="White" FontSize="12.5" VerticalAlignment="Center" MaxWidth="520" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
          </Border>
        </Grid>
      </Border>
    </Grid>

    <!-- update index panel; the shared folder setting is behind "Advanced" + password -->
    <Border x:Name="panel" Grid.Row="1" Grid.RowSpan="2" Visibility="Collapsed" Panel.ZIndex="10" HorizontalAlignment="Right" VerticalAlignment="Top"
            Margin="0,54,20,12" Width="450" Background="White" CornerRadius="16" BorderBrush="#E2E8F0" BorderThickness="1" Padding="22,20,10,18">
      <Border.Effect><DropShadowEffect BlurRadius="30" ShadowDepth="6" Opacity="0.22" Color="#0F172A"/></Border.Effect>
      <Border.Resources>
        <Style TargetType="TextBox">
          <Setter Property="Foreground" Value="#0F172A"/>
          <Setter Property="FontSize" Value="13.5"/>
          <Setter Property="Padding" Value="9,7"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="TextBox">
                <Border x:Name="bd" Background="White" BorderBrush="#CBD5E1" BorderThickness="1" CornerRadius="8">
                  <ScrollViewer x:Name="PART_ContentHost" Margin="0" VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#93C5FD"/></Trigger>
                  <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bd" Property="BorderBrush" Value="#2563EB"/></Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Style>
        <Style x:Key="Sec" TargetType="TextBlock">
          <Setter Property="FontSize" Value="10.5"/>
          <Setter Property="FontWeight" Value="Bold"/>
          <Setter Property="Foreground" Value="#64748B"/>
          <Setter Property="Margin" Value="0,18,0,7"/>
        </Style>
        <Style x:Key="Cap" TargetType="TextBlock">
          <Setter Property="FontSize" Value="12"/>
          <Setter Property="Foreground" Value="#475569"/>
          <Setter Property="Margin" Value="0,0,0,5"/>
        </Style>
        <Style x:Key="Seg" TargetType="RadioButton">
          <Setter Property="Foreground" Value="#475569"/>
          <Setter Property="FontSize" Value="13"/>
          <Setter Property="Cursor" Value="Hand"/>
          <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="RadioButton">
                <Border x:Name="b" Background="Transparent" CornerRadius="9" Padding="10,7">
                  <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#1E40AF"/></Trigger>
                  <Trigger Property="IsChecked" Value="True">
                    <Setter TargetName="b" Property="Background" Value="White"/>
                    <Setter TargetName="b" Property="Effect"><Setter.Value><DropShadowEffect BlurRadius="6" ShadowDepth="1" Opacity="0.16" Color="#0F172A"/></Setter.Value></Setter>
                    <Setter Property="Foreground" Value="#1D4ED8"/>
                    <Setter Property="FontWeight" Value="SemiBold"/>
                  </Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Style>
        <Style x:Key="Opt" TargetType="CheckBox">
          <Setter Property="Cursor" Value="Hand"/>
          <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="CheckBox">
                <Border x:Name="card" Background="White" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="10" Padding="12,10">
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border x:Name="box" Width="18" Height="18" CornerRadius="5" BorderBrush="#94A3B8" BorderThickness="1.5" Background="White" VerticalAlignment="Top" Margin="0,1,12,0">
                      <TextBlock x:Name="tick" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
                    </Border>
                    <ContentPresenter Grid.Column="1"/>
                  </Grid>
                </Border>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="card" Property="BorderBrush" Value="#93C5FD"/></Trigger>
                  <Trigger Property="IsChecked" Value="True">
                    <Setter TargetName="card" Property="Background" Value="#F5F9FF"/>
                    <Setter TargetName="box" Property="Background" Value="#2563EB"/>
                    <Setter TargetName="box" Property="BorderBrush" Value="#2563EB"/>
                    <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
                  </Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Style>
      </Border.Resources>
      <ScrollViewer VerticalScrollBarVisibility="Auto">
      <StackPanel Margin="0,0,12,0">
        <DockPanel>
          <Border DockPanel.Dock="Left" Width="40" Height="40" CornerRadius="20" Background="#DBEAFE" Margin="0,0,12,0" VerticalAlignment="Top">
            <TextBlock Text="&#xE72C;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="#1D4ED8" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel>
            <TextBlock Text="Update index" FontSize="18" FontWeight="Bold" Foreground="#1E3A8A"/>
            <TextBlock Text="I read only file names, sizes and dates - never what is inside the files." Foreground="#64748B" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,0"/>
          </StackPanel>
        </DockPanel>

        <TextBlock Style="{StaticResource Sec}" Text="WHAT TO INDEX"/>
        <Border Background="#EEF2F7" CornerRadius="12" Padding="3">
          <UniformGrid Columns="2">
            <RadioButton x:Name="rbModeNas" Style="{StaticResource Seg}" GroupName="idxmode" IsChecked="True">
              <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE8CE;" FontFamily="Segoe MDL2 Assets" FontSize="13" VerticalAlignment="Center" Margin="0,1,8,0"/><TextBlock Text="Common drive"/></StackPanel>
            </RadioButton>
            <RadioButton x:Name="rbModePc" Style="{StaticResource Seg}" GroupName="idxmode">
              <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7F4;" FontFamily="Segoe MDL2 Assets" FontSize="13" VerticalAlignment="Center" Margin="0,1,8,0"/><TextBlock Text="This PC"/></StackPanel>
            </RadioButton>
          </UniformGrid>
        </Border>
        <Border Background="#F8FAFC" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="10" Padding="13,11" Margin="0,10,0,0">
          <StackPanel>
            <TextBlock x:Name="lblModeInfo" FontSize="12" Foreground="#475569" TextWrapping="Wrap" LineHeight="17"/>
            <Border Height="1" Background="#E2E8F0" Margin="0,9,0,9"/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Text="&#xE823;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="#2563EB" VerticalAlignment="Top" Margin="0,2,9,0"/>
              <StackPanel Grid.Column="1">
                <TextBlock x:Name="lblIdxState" FontSize="12.5" FontWeight="SemiBold" Foreground="#1E3A8A" TextWrapping="Wrap"/>
                <TextBlock x:Name="lblIdxMeta" Style="{StaticResource Msg}" FontSize="11.5" Foreground="#64748B" Margin="0,2,0,0"/>
              </StackPanel>
            </Grid>
          </StackPanel>
        </Border>
        <TextBlock x:Name="lblIndexMsg" Style="{StaticResource Msg}" Text="" Foreground="#B45309" FontSize="12.5" Margin="0,8,0,0"/>

        <TextBlock Style="{StaticResource Sec}" Text="LOCATION"/>
        <TextBlock x:Name="lblDriveCap" Style="{StaticResource Cap}" Text="Drive or folder to scan (separate several with ;)"/>
        <TextBox x:Name="txtDrive"/>
        <TextBlock x:Name="vDrive" FontSize="11.5" TextWrapping="Wrap" Margin="0,4,0,0" Visibility="Collapsed"/>

        <StackPanel x:Name="pcOpts" Visibility="Collapsed">
          <TextBlock Style="{StaticResource Sec}" Text="WHAT TO LEAVE OUT"/>
          <CheckBox x:Name="chkSkipSys" Style="{StaticResource Opt}" IsChecked="True">
            <StackPanel>
              <TextBlock Text="Skip system folders" FontSize="13" FontWeight="SemiBold" Foreground="#0F172A"/>
              <TextBlock Text="Windows, Program Files, ProgramData, AppData and the recycle bin." FontSize="11.5" Foreground="#64748B" TextWrapping="Wrap" Margin="0,2,0,0"/>
            </StackPanel>
          </CheckBox>
          <CheckBox x:Name="chkDocsOnly" Style="{StaticResource Opt}" IsChecked="True" Margin="0,8,0,0">
            <StackPanel>
              <TextBlock Text="Only useful files" FontSize="13" FontWeight="SemiBold" Foreground="#0F172A"/>
              <TextBlock Text="PDF, Word, Excel, PowerPoint, images, drawings, e-mails, archives, videos and setup files. All folders are kept." FontSize="11.5" Foreground="#64748B" TextWrapping="Wrap" Margin="0,2,0,0"/>
            </StackPanel>
          </CheckBox>
        </StackPanel>

        <TextBlock Style="{StaticResource Sec}" Text="SCAN SETTINGS"/>
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <StackPanel>
            <TextBlock Style="{StaticResource Cap}" Text="Folder depth (empty = all)"/>
            <TextBox x:Name="txtDepth"/>
          </StackPanel>
          <StackPanel Grid.Column="2">
            <TextBlock Style="{StaticResource Cap}" Text="Threads (16 recommended)"/>
            <TextBox x:Name="txtThreads"/>
          </StackPanel>
        </Grid>
        <TextBlock x:Name="vDepth" FontSize="11.5" TextWrapping="Wrap" Margin="0,5,0,0" Visibility="Collapsed"/>
        <TextBlock x:Name="vThreads" FontSize="11.5" TextWrapping="Wrap" Margin="0,5,0,0" Visibility="Collapsed"/>
        <TextBlock x:Name="lblDepthHint" Style="{StaticResource Msg}" Text="" Foreground="#64748B" FontSize="11.5" Margin="0,8,0,0"/>

        <Border x:Name="advSection" Visibility="Collapsed" Background="#F8FAFC" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="10" Padding="13,12" Margin="0,16,0,0">
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE785;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="#1D4ED8" VerticalAlignment="Center" Margin="0,1,7,0"/>
              <TextBlock Text="Shared index folder" FontSize="13" FontWeight="SemiBold" Foreground="#1E3A8A"/>
            </StackPanel>
            <TextBlock x:Name="advHint" FontSize="11.5" Foreground="#64748B" TextWrapping="Wrap" Margin="0,4,0,0"/>
            <Grid Margin="0,9,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBox x:Name="txtIndex" FontSize="12.5"/>
              <Button x:Name="btnBrowse" Grid.Column="2" Content="Browse..." Style="{StaticResource Ghost}" Padding="12,6"/>
            </Grid>
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <Button x:Name="btnUse" Content="Use this folder" Style="{StaticResource Ghost}" Padding="12,6" Margin="0,0,8,0"/>
              <Button x:Name="btnShowIdx" Style="{StaticResource Ghost}" Padding="12,6">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE838;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center" Margin="0,1,7,0"/>
                  <TextBlock Text="Show index file"/>
                </StackPanel>
              </Button>
            </StackPanel>
            <Grid x:Name="advGrid" Margin="0,12,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            </Grid>
          </StackPanel>
        </Border>

        <TextBlock x:Name="lblProg" Style="{StaticResource Msg}" Text="" Foreground="#1E40AF" FontSize="12.5" FontWeight="SemiBold" Margin="0,14,0,0"/>
        <Border Height="1" Background="#EEF2F7" Margin="0,16,0,12"/>
        <DockPanel>
          <Button x:Name="btnAdv" DockPanel.Dock="Left" Style="{StaticResource Ghost}" BorderThickness="0" Background="Transparent" Padding="6,6" Foreground="#64748B">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" FontSize="11" VerticalAlignment="Center" Margin="0,1,6,0"/>
              <TextBlock x:Name="advLbl" Text="Advanced" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="btnClose" Content="Close" Style="{StaticResource Ghost}" Margin="0,0,8,0"/>
            <Button x:Name="btnStart" Content="Start indexing" Style="{StaticResource Accent}"/>
          </StackPanel>
        </DockPanel>
      </StackPanel>
      </ScrollViewer>
    </Border>

    <!-- "take me to another PC" panel -->
    <Border x:Name="sharePanel" Grid.Row="1" Grid.RowSpan="2" Visibility="Collapsed" Panel.ZIndex="11" HorizontalAlignment="Right" VerticalAlignment="Top"
            Margin="0,54,20,12" Width="450" Background="White" CornerRadius="16" BorderBrush="#E2E8F0" BorderThickness="1" Padding="6">
      <Border.Effect><DropShadowEffect BlurRadius="30" ShadowDepth="6" Opacity="0.22" Color="#0F172A"/></Border.Effect>
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="16,12,16,16">
          <DockPanel>
            <Button x:Name="btnShareClose" DockPanel.Dock="Right" Content="&#xE711;" FontFamily="Segoe MDL2 Assets" FontSize="11" Style="{StaticResource Ghost}" BorderThickness="0" Padding="8,6" VerticalAlignment="Top"/>
            <Border DockPanel.Dock="Left" Width="40" Height="40" CornerRadius="20" Background="#DBEAFE" Margin="0,0,12,0" VerticalAlignment="Top">
              <TextBlock Text="&#xE896;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="#1D4ED8" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel>
              <TextBlock Text="Take me to another PC" FontSize="18" FontWeight="Bold" Foreground="#1E3A8A"/>
              <TextBlock Text="I am just three small files - no installation and no admin rights needed." FontSize="12" Foreground="#64748B" TextWrapping="Wrap" Margin="0,2,0,0"/>
            </StackPanel>
          </DockPanel>
          <StackPanel x:Name="shareBody" Margin="0,4,0,0"/>
          <Border Background="#EFF6FF" BorderBrush="#BFDBFE" BorderThickness="1" CornerRadius="12" Padding="14,12" Margin="0,16,0,0">
            <StackPanel>
              <TextBlock Text="Download me as a zip file" FontSize="13.5" FontWeight="SemiBold" Foreground="#1E3A8A"/>
              <TextBlock Text="You choose where to save me - the Desktop is a good place. The zip also has a short read-me with these steps." FontSize="12" Foreground="#475569" TextWrapping="Wrap" Margin="0,3,0,0"/>
              <Button x:Name="btnZip" Style="{StaticResource Accent}" HorizontalAlignment="Left" Margin="0,12,0,0">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE896;" FontFamily="Segoe MDL2 Assets" FontSize="13" VerticalAlignment="Center" Margin="0,1,8,0"/>
                  <TextBlock Text="Download zip" VerticalAlignment="Center"/>
                </StackPanel>
              </Button>
              <TextBlock x:Name="zipMsg" Style="{StaticResource Msg}" Text="" FontSize="12" Margin="0,10,0,0"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>
    </Border>

    <!-- help / info panel -->
    <Border x:Name="helpPanel" Grid.Row="1" Grid.RowSpan="2" Visibility="Collapsed" Panel.ZIndex="11" HorizontalAlignment="Right" VerticalAlignment="Top"
            Margin="0,54,20,12" Width="420" Background="White" CornerRadius="16" BorderBrush="#E2E8F0" BorderThickness="1" Padding="6">
      <Border.Effect><DropShadowEffect BlurRadius="30" ShadowDepth="6" Opacity="0.22" Color="#0F172A"/></Border.Effect>
      <ScrollViewer VerticalScrollBarVisibility="Auto" MaxHeight="620">
        <StackPanel Margin="16,12,16,14">
          <DockPanel>
            <Button x:Name="btnHelpClose" DockPanel.Dock="Right" Content="&#xE711;" FontFamily="Segoe MDL2 Assets" FontSize="11" Style="{StaticResource Ghost}" BorderThickness="0" Padding="8,6"/>
            <TextBlock Text="Help and tips" FontSize="18" FontWeight="Bold" Foreground="#1E3A8A" VerticalAlignment="Center"/>
          </DockPanel>
          <StackPanel x:Name="helpBody" Margin="0,4,0,0"/>
        </StackPanel>
      </ScrollViewer>
    </Border>

    <!-- password prompt -->
    <Grid x:Name="lockOverlay" Grid.RowSpan="4" Visibility="Collapsed" Panel.ZIndex="20" Background="#590F172A">
      <Border Width="350" Background="White" CornerRadius="16" Padding="24" HorizontalAlignment="Center" VerticalAlignment="Center">
        <Border.Effect><DropShadowEffect BlurRadius="34" ShadowDepth="6" Opacity="0.25" Color="#0F172A"/></Border.Effect>
        <StackPanel>
          <Border Width="44" Height="44" CornerRadius="22" Background="#DBEAFE" HorizontalAlignment="Left">
            <TextBlock Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" FontSize="18" Foreground="#1D4ED8" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Text="Admin access" FontSize="18" FontWeight="Bold" Foreground="#0F172A" Margin="0,14,0,0"/>
          <TextBlock Text="Enter the admin password to change the shared index folder." FontSize="12.5" Foreground="#64748B" TextWrapping="Wrap" Margin="0,4,0,0"/>
          <PasswordBox x:Name="pwdBox" Padding="8,7" FontSize="14" Margin="0,16,0,0"/>
          <TextBlock x:Name="pwdMsg" Foreground="#DC2626" FontSize="12" Margin="0,6,0,0"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
            <Button x:Name="pwdCancel" Content="Cancel" Style="{StaticResource Ghost}" Margin="0,0,8,0"/>
            <Button x:Name="pwdOk" Content="Unlock" Style="{StaticResource Accent}"/>
          </StackPanel>
        </StackPanel>
      </Border>
    </Grid>

    <!-- confirmation box (close the app, update the index) -->
    <Grid x:Name="dlgOverlay" Grid.RowSpan="4" Visibility="Collapsed" Panel.ZIndex="30" Background="#590F172A">
      <Border Width="430" Background="White" CornerRadius="16" Padding="24" HorizontalAlignment="Center" VerticalAlignment="Center">
        <Border.Effect><DropShadowEffect BlurRadius="34" ShadowDepth="6" Opacity="0.25" Color="#0F172A"/></Border.Effect>
        <StackPanel>
          <Border Width="44" Height="44" CornerRadius="22" Background="#DBEAFE" HorizontalAlignment="Left">
            <TextBlock x:Name="dlgIco" FontFamily="Segoe MDL2 Assets" FontSize="18" Foreground="#1D4ED8" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock x:Name="dlgTitle" FontSize="18" FontWeight="Bold" Foreground="#0F172A" TextWrapping="Wrap" Margin="0,14,0,0"/>
          <TextBlock x:Name="dlgMsg" FontSize="13" Foreground="#475569" TextWrapping="Wrap" LineHeight="19" Margin="0,8,0,0"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
            <Button x:Name="dlgCancel" Content="Cancel" Style="{StaticResource Ghost}" MinWidth="92" Margin="0,0,8,0"/>
            <Button x:Name="dlgOk" Content="OK" Style="{StaticResource Accent}" MinWidth="92"/>
          </StackPanel>
        </StackPanel>
      </Border>
    </Grid>

    <Grid Grid.Row="3" Background="#E7EEFA">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel Orientation="Horizontal" Margin="18,0,0,0" VerticalAlignment="Center">
        <TextBlock x:Name="lblCount" FontSize="12" FontWeight="SemiBold" Foreground="#0F172A" VerticalAlignment="Center"/>
        <TextBlock x:Name="lblTime" FontSize="11.5" Foreground="#64748B" VerticalAlignment="Center" Margin="6,0,18,0"/>
        <TextBlock x:Name="lblStatus" FontSize="12" FontWeight="SemiBold" Foreground="#1E40AF" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
      <TextBlock Grid.Column="1" Text="Developed by ETO" Margin="0,0,18,0" FontSize="11" Foreground="#64748B" VerticalAlignment="Center"/>
    </Grid>
  </Grid>
</Window>
'@

$w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
foreach ($n in 'topPanel','title','heroPills','hItems','hDepth','hUpdated','cItems','cDepth','cUpdated','chipBar','searchBox','hint','btnClear',
               'tScopeAll','tName','tPath','tTypeAll','tPdf','tXls','tDoc','tImg','rbAll','rbFiles','rbDirs','tipLbl','btnHelp','btnIdx','results','btnCols','lblCount','lblTime',
               'list','gridList','gridMore','gridMoreText','viewToggle','tbList','tbGrid','emptyState','emptyText','openToast','spinner','toastText','panel','lblIndexMsg','txtDrive','vDrive','txtDepth','vDepth',
               'txtThreads','vThreads','lblDepthHint','advSection','txtIndex','btnBrowse','btnUse','lblProg','btnAdv','advLbl','btnClose','btnStart',
               'helpPanel','btnHelpClose','helpBody','lockOverlay','pwdBox','pwdMsg','pwdCancel','pwdOk','lblStatus',
               'rbModeNas','rbModePc','lblModeInfo','lblIdxState','lblDriveCap','pcOpts','chkSkipSys','chkDocsOnly','advInfo',
               'dlgOverlay','dlgIco','dlgTitle','dlgMsg','dlgCancel','dlgOk','greetRow','greetIco','greetTxt','greetEmo','btnShare','sharePanel','btnShareClose',
               'shareBody','btnZip','zipMsg','emptyHint','btnResetFilters','lblIdxMeta','advHint','advGrid','btnShowIdx') {
    Set-Variable -Name $n -Value $w.FindName($n) -Scope Script
}
try { $w.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$icoPath, [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad) } catch { }

$txtDrive.Text = $cfg['drive']; $txtDepth.Text = $cfg['depth']; $txtThreads.Text = $cfg['threads']
$script:scopeName = ($cfg['scope'] -ne 'path')
$script:scopePath = ($cfg['scope'] -ne 'name')

$gv = $list.View
[US.Cols]::Build($gv, $cfg['cols2'])

# grid tiles are built from the same Hit objects as the list
$tileFactory = New-Object System.Windows.FrameworkElementFactory ([US.TileRow])
$tileFactory.SetBinding([US.TileRow]::ItemsProperty, (New-Object System.Windows.Data.Binding))
$tileTemplate = New-Object System.Windows.DataTemplate
$tileTemplate.VisualTree = $tileFactory
$gridList.ItemTemplate = $tileTemplate
$script:viewMode = 'list'     # 'list' or 'grid'
$script:gridHit = $null       # the tile last clicked / right-clicked in the grid
$gridPager = New-Object US.GridPager
$gridPageSize = 120           # tiles added at a time
$script:autoGrid = $false     # was the grid chosen automatically for images?
$searcher = New-Object US.Searcher -ArgumentList $list, $lblCount, $lblTime, $emptyState, $emptyText
$script:userChoseView = $false
[US.Ui]::EnableDrag($list)

$zoomTf = New-Object System.Windows.Media.ScaleTransform 1, 1
$list.LayoutTransform = $zoomTf
$spinRot = New-Object System.Windows.Media.RotateTransform
$spinner.RenderTransform = $spinRot

# ---------------- state ----------------
$script:idx = $null            # what is searched: common drive + this PC
$script:nasIdx = $null; $script:nasMeta = ''; $script:nasFile = ''
$script:pcIdx = $null;  $script:pcMeta = ''
$script:loads = New-Object System.Collections.ArrayList
$script:syncJob = $null
$script:lastSync = [DateTime]::MinValue
$script:syncAfterLoad = $false
$script:legacyTried = $false
$script:idxMode = 'nas'         # Update index panel: 'nas' = common drive, 'pc' = this PC
$script:ixMode = 'nas'
$script:lockSet = $false
$script:closeOk = $false
$script:dlgAction = $null
$script:indexer = $null
$script:compact = $false
$script:sw = $null
$script:zoom = 1.0
$script:years = New-Object System.Collections.ArrayList
$script:typeSel = New-Object System.Collections.ArrayList
$script:openRecent = @{}
$script:toastJob = $null
$script:toastStart = [DateTime]::MinValue
$script:toastErr = $false
$script:lastSpace = [DateTime]::MinValue
$inv = [Globalization.CultureInfo]::InvariantCulture
$bullet = [string][char]0x2022
$arrow = [string][char]0x2192

$typeDefs = [ordered]@{
    'PDF'            = 'pdf'
    'Excel'          = 'xls,xlsx,xlsm,xlsb,xlt,xltx,xltm,csv,ods'
    'Images'         = 'jpg,jpeg,jpe,jfif,png,gif,bmp,dib,tif,tiff,webp,heic,heif,svg,ico,raw,cr2,nef,arw,dng,psd'
    'Word'           = 'doc,docx,docm,rtf,odt'
    'PowerPoint'     = 'ppt,pptx,pptm,odp'
    'Drawings / CAD' = 'dwg,dxf,dgn,dwf,step,stp,iges,igs,sldprt,sldasm,ipt,iam'
    'Video'          = 'mp4,mkv,avi,mov,wmv,m4v'
    'Archives'       = 'zip,rar,7z,tar,gz,iso'
    'Text'           = 'txt,log,ini,xml,json'
}
# "This PC" with "Only useful files": the extensions that are kept (folders are always kept)
$pcExts = 'pdf,doc,docx,docm,dot,dotx,dotm,rtf,odt,wpd,txt,md,xps,oxps,epub,one,' +
          'xls,xlsx,xlsm,xlsb,xlt,xltx,xltm,xlam,csv,tsv,ods,ppt,pptx,pptm,pps,ppsx,pot,potx,odp,vsd,vsdx,' +
          'jpg,jpeg,jpe,jfif,png,gif,bmp,dib,tif,tiff,webp,heic,heif,svg,ico,raw,cr2,cr3,nef,arw,dng,orf,rw2,psd,ai,eps,emf,wmf,' +
          'dwg,dxf,dwf,dgn,step,stp,iges,igs,msg,eml,pst,zip,rar,7z,iso,' +
          'mp4,mkv,avi,mov,wmv,m4v,mpg,mpeg,3gp,mp3,wav,m4a,wma,exe,msi'
function Get-CatExts { return (@($script:typeSel | ForEach-Object { $typeDefs[$_] }) -join ',') }

$menuStyle = $w.FindResource('MenuStyle')
$miStyle   = $w.FindResource('MiStyle')
$sepStyle  = $w.FindResource('SepStyle')
$chipStyle = $w.FindResource('ChipBtn')
function New-Menu {
    $m = New-Object System.Windows.Controls.ContextMenu
    $m.Style = $menuStyle
    return $m
}
function New-Mi([string]$text, $tag, [string]$glyph = '', [string]$gesture = '') {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Style = $miStyle
    $mi.Header = $text; $mi.Tag = $tag
    if ($gesture) { $mi.InputGestureText = $gesture }
    if ($glyph) {
        $g = New-Object System.Windows.Controls.TextBlock
        $g.Text = $glyph; $g.FontFamily = 'Segoe MDL2 Assets'; $g.FontSize = 12; $g.Foreground = '#475569'
        $mi.Icon = $g
    }
    return $mi
}
function New-MenuLabel([string]$text) {
    $mi = New-Mi $text 'label'
    $mi.IsEnabled = $false; $mi.FontSize = 10.5; $mi.FontWeight = 'Bold'
    return $mi
}
function New-Sep { $s = New-Object System.Windows.Controls.Separator; $s.Style = $sepStyle; return $s }

function Get-HeroTop { return [Math]::Max(20, [int]($w.ActualHeight * 0.20)) }

function Set-Mode([bool]$compact) {
    if ($script:compact -eq $compact) { return }
    $script:compact = $compact
    if ($compact) {
        [US.Ui]::AnimMargin($topPanel, 10, 350)
        [US.Ui]::AnimFont($title, 22, 350)
        $heroPills.Visibility = 'Collapsed'
        $greetRow.Visibility = 'Collapsed'
        $tipLbl.Visibility = 'Collapsed'
        $title.Margin = '0,0,0,8'
        $results.Visibility = 'Visible'
        [US.Ui]::FadeIn($results, 350)
    } else {
        [US.Ui]::AnimMargin($topPanel, (Get-HeroTop), 350)
        [US.Ui]::AnimFont($title, 42, 350)
        $heroPills.Visibility = 'Visible'
        $greetRow.Visibility = 'Visible'
        $tipLbl.Visibility = 'Visible'
        $title.Margin = '0'
        $results.Visibility = 'Collapsed'
    }
}

# greeting above the title, by the time on this PC
function Update-Greeting {
    $h = [DateTime]::Now.Hour
    # smileys: bird, smiling sun, sunglasses, evening tea, sleeping face with zzz
    if ($h -ge 4 -and $h -lt 6)       { $t = 'Hello, early bird';  $g = 0xE706; $c = '#F59E0B'; $e = 0x1F426 }
    elseif ($h -ge 6 -and $h -lt 12)  { $t = 'Good morning, Crew'; $g = 0xE706; $c = '#F59E0B'; $e = 0x1F31E }
    elseif ($h -ge 12 -and $h -lt 17) { $t = 'Good noon, Crew';    $g = 0xE706; $c = '#F97316'; $e = 0x1F60E }
    elseif ($h -ge 17 -and $h -lt 23) { $t = 'Good evening, Crew'; $g = 0xE708; $c = '#6366F1'; $e = 0x1F375 }
    else                               { $t = 'Hello, night owl';   $g = 0xE708; $c = '#6366F1'; $e = 0x1F634 }
    $greetTxt.Text = $t
    $greetEmo.Text = [char]::ConvertFromUtf32($e)
    $greetEmo.Foreground = $c
    $greetIco.Text = [string][char]$g
    $greetIco.Foreground = $c
}
function Set-InfoText([string]$items, [string]$depth, [string]$upd) {
    $hItems.Text = $items; $cItems.Text = $items
    $hDepth.Text = $depth; $cDepth.Text = $depth
    $hUpdated.Text = $upd; $cUpdated.Text = $upd
}

function Get-RootsText([string]$t) {
    return (@($t -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') } | Where-Object { $_ }) -join ';').ToUpperInvariant()
}
function Get-NasRoots {
    $r = [string][US.IndexFile]::Get($script:nasMeta, 'roots')
    if (-not $r) { $r = [string]$cfg['drive'] }
    return $r
}
function Get-IndexDepth {
    # folder depth (levels below the scanned root) that the common drive index covers
    if (-not $script:nasIdx) { return 0 }
    $root = (@((Get-NasRoots) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) + @('X:\'))[0]
    if ($root -notmatch '\\$') { $root += '\' }
    $rc = [US.IndexData]::Slashes($root)
    return [Math]::Max(1, $script:nasIdx.MaxDepth - ($rc - 1))
}

function Get-MetaTime([string]$meta, [string]$path) {
    $b = [string][US.IndexFile]::Get($meta, 'built')
    $dt = [DateTime]::MinValue
    if ($b -and [DateTime]::TryParseExact($b, 'yyyy-MM-dd HH:mm:ss', $inv, [Globalization.DateTimeStyles]::None, [ref]$dt)) { return $dt }
    if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return (Get-Item -LiteralPath $path).LastWriteTime }
    return $null
}
function Format-When($dt) { if (-not $dt) { return '-' }; return $dt.ToString('dd-MMM-yyyy  hh:mm tt', $inv) }
# "just now", "25 min ago", "3 h 10 min ago", "1 day 5 h ago" (never seconds)
function Format-Ago($dt) {
    if (-not $dt) { return '-' }
    $s = [DateTime]::Now - $dt
    if ($s.TotalMinutes -lt 1) { return 'just now' }
    $d = [int][Math]::Floor($s.TotalDays); $h = $s.Hours; $m = $s.Minutes
    if ($d -ge 1) { return ('{0} {1}{2} ago' -f $d, $(if ($d -eq 1) { 'day' } else { 'days' }), $(if ($h -gt 0) { ' ' + $h + ' h' } else { '' })) }
    if ($h -ge 1) { return ('{0} h{1} ago' -f $h, $(if ($m -gt 0) { ' ' + $m + ' min' } else { '' })) }
    return ('{0} min ago' -f $m)
}
function Get-FileSizeText([string]$p) {
    try { if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return [US.Ui]::FormatSize((Get-Item -LiteralPath $p).Length) } } catch { }
    return ''
}

function Update-IdxState {
    $dot = '   ' + [string][char]0x00B7 + '   '
    if ($script:idxMode -eq 'pc') {
        $lblModeInfo.Text = 'I index the documents on this computer. This index stays on this PC only, and I search it together with the common drive.'
        if ($script:pcIdx) {
            $lblIdxState.Text = 'Last index updated:  ' + (Format-When (Get-MetaTime $script:pcMeta $pcIndexPath))
            $lblIdxMeta.Text = ('{0:N0} items' -f $script:pcIdx.Items.Count) + $dot + (Get-FileSizeText $pcIndexPath)
        } else { $lblIdxState.Text = 'This PC is not indexed yet.'; $lblIdxMeta.Text = '' }
    } else {
        $lblModeInfo.Text = 'I index the common drive and save the index in the shared folder. Every PC gets it automatically - one update is enough for everyone.'
        if ($script:nasIdx) {
            $by = [string][US.IndexFile]::Get($script:nasMeta, 'by')
            $lblIdxState.Text = 'Last index updated:  ' + (Format-When (Get-MetaTime $script:nasMeta $script:nasFile))
            $lblIdxMeta.Text = ('{0:N0} items' -f $script:nasIdx.Items.Count) + $(if ($by) { $dot + 'by ' + $by } else { '' }) + $(if ((Get-FileSizeText $script:nasFile)) { $dot + (Get-FileSizeText $script:nasFile) } else { '' })
        } else { $lblIdxState.Text = 'The common drive is not indexed yet.'; $lblIdxMeta.Text = '' }
    }
}

function Update-Info {
    Update-IdxState
    if (-not $script:nasIdx -and -not $script:pcIdx) { return }
    $n = 0
    if ($script:nasIdx) { $n += $script:nasIdx.Items.Count }
    if ($script:pcIdx) { $n += $script:pcIdx.Items.Count }
    $when = if ($script:nasIdx) { Get-MetaTime $script:nasMeta $script:nasFile } else { Get-MetaTime $script:pcMeta $pcIndexPath }
    $d = Get-IndexDepth
    # the depth that was asked for when indexing; empty = everything = "full"
    $meta = if ($script:nasIdx) { $script:nasMeta } else { $script:pcMeta }
    $asked = [string][US.IndexFile]::Get($meta, 'depth')
    $dtext = if ($asked) { $asked } elseif ([US.IndexFile]::Get($meta, 'built')) { 'full' } elseif ($d -gt 0) { [string]$d } else { 'full' }
    Set-InfoText ('{0:N0} items indexed' -f $n) ('Folder depth ' + $dtext) ('Last index updated ' + (Format-Ago $when))
    $hUpdated.ToolTip = Format-When $when
    $lblDepthHint.Text = $(if ($d -gt 0) { 'The common drive index has folder depth {0}. Leave Folder depth empty to scan everything, or enter {0} or more.' -f $d } else { '' })
}

# True when the current search is only about images (Images type chosen, or an image extension typed)
function Test-ImageQuery {
    if ($script:typeSel.Count -gt 0) { return (@($script:typeSel | Where-Object { $_ -ne 'Images' }).Count -eq 0 -and ($script:typeSel -contains 'Images')) }
    $t = $searchBox.Text
    if ($t -match '(?i)(^|\s)(ext:\s*)?\*?\.?(jpe?g|jfif|png|gif|bmp|tiff?|webp|heic|heif|ico|svg|cr2|cr3|nef|arw|dng|raw|psd)(\s|$)') { return $true }
    return $false
}
function Set-ViewMode([string]$m) {
    $script:viewMode = $m
    $tbList.IsChecked = ($m -eq 'list')
    $tbGrid.IsChecked = ($m -eq 'grid')
    if ($m -eq 'grid') {
        Sync-Grid $true
        $list.Visibility = 'Collapsed'; $gridList.Visibility = 'Visible'
    } else {
        $gridList.ItemsSource = $null
        $gridPager.SetSource($null, 0)
        $gridList.Visibility = 'Collapsed'; $list.Visibility = 'Visible'
        $gridMore.Visibility = 'Collapsed'
    }
}
# grid shows the list's results a page at a time, as rows that fit the window width
function Set-GridCols {
    $wd = $gridList.ActualWidth
    if ($wd -le 0) { $wd = $results.ActualWidth - 20 }
    # as many columns as fit; the columns then share the width equally, so no empty strip is left on the right
    $c = [Math]::Max(1, [int][Math]::Floor(($wd - 26) / ([US.Tile]::Thumb + 34)))
    [US.TileRow]::Cols = $c
    return $gridPager.SetCols($c)
}
function Update-GridNote {
    if ($script:viewMode -eq 'grid' -and $gridPager.HasMore) {
        $gridMoreText.Text = ('Showing {0:N0} of {1:N0} images - scroll down for more' -f $gridPager.Count, $gridPager.Total)
        $gridMore.Visibility = 'Visible'
    } else { $gridMore.Visibility = 'Collapsed' }
}
function Sync-Grid([bool]$force) {
    $src = $list.ItemsSource
    if (-not $force -and [object]::ReferenceEquals($gridPager.Source, $src)) { return }
    [void](Set-GridCols)
    $gridPager.SetSource($src, $gridPageSize)
    $script:gridHit = $null
    if (-not [object]::ReferenceEquals($gridList.ItemsSource, $gridPager.Rows)) { $gridList.ItemsSource = $gridPager.Rows }
    $sv = [US.Ui]::FindScroller($gridList)
    if ($sv) { $sv.ScrollToTop() }
    Update-GridNote
}
function Update-List {
    $kind = 0
    if ($rbFiles.IsChecked) { $kind = 1 } elseif ($rbDirs.IsChecked) { $kind = 2 }
    $q = [US.Query]::Parse($searchBox.Text, $kind, [bool]$script:scopePath, (Get-CatExts), [int[]]@($script:years))
    if ($q.IsEmpty) { $searcher.Clear(); Set-Mode $false; $viewToggle.Visibility = 'Collapsed'; $script:userChoseView = $false; return }
    Set-Mode $true
    # offer the grid for image searches, and switch to it once automatically
    $img = Test-ImageQuery
    $viewToggle.Visibility = $(if ($img) { 'Visible' } else { 'Collapsed' })
    if ($img) {
        if ($script:viewMode -ne 'grid' -and -not $script:userChoseView) { Set-ViewMode 'grid'; $script:autoGrid = $true }
    } else {
        if ($script:viewMode -ne 'list') { Set-ViewMode 'list' }
        $script:autoGrid = $false
    }
    if ($script:viewMode -eq 'grid') { $script:pendingGrid = $true }
    $on = Test-FiltersOn
    $btnResetFilters.Visibility = $(if ($on) { 'Visible' } else { 'Collapsed' })
    $emptyHint.Text = $(if ($on) { 'Some filters are switched on - they may be hiding what you are looking for.' } else { 'Try fewer words or check the spelling.' })
    if (-not $searcher.Index) { $lblCount.Text = 'Index is still loading...'; $lblTime.Text = ''; return }
    [void]$searcher.Run($q)
}

function Show-Status([string]$t) {
    $lblStatus.Text = $t
    $statusTimer.Stop(); $statusTimer.Start()
}

# ---------------- opening files (single click, with an "Opening..." indicator) ----------------
function Show-Toast([string]$t, $job) {
    $toastText.Text = $t
    $spinner.Visibility = 'Visible'
    $openToast.Visibility = 'Visible'
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation 0, 360, ([System.Windows.Duration][TimeSpan]::FromSeconds(0.9))
    $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $spinRot.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $a)
    $script:toastJob = $job
    $script:toastErr = $false
    $script:toastStart = [DateTime]::Now
    $toastTimer.Start()
}
function Hide-Toast {
    $toastTimer.Stop()
    $spinRot.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
    $openToast.Visibility = 'Collapsed'
}
function Open-Item($it) {
    if (-not $it) { return }
    $now = [DateTime]::Now
    $last = $script:openRecent[$it.FullName]
    if ($last -and ($now - $last).TotalSeconds -lt 4) { Show-Toast ('Already opening ' + $it.Name + ' - please wait...') $script:toastJob; return }
    $script:openRecent[$it.FullName] = $now
    Show-Toast ('Opening ' + $it.Name + '...') ([US.Ui]::OpenAsync($it.FullName, $it.IsDir))
}
function Open-Folder($it) {
    if (-not $it) { return }
    $key = '>' + $it.FullName
    $now = [DateTime]::Now
    $last = $script:openRecent[$key]
    if ($last -and ($now - $last).TotalSeconds -lt 3) { return }
    $script:openRecent[$key] = $now
    Show-Toast ('Opening folder of ' + $it.Name + '...') ([US.Ui]::ShowInFolderAsync($it.FullName))
}
function Show-InFolder($it) { Open-Folder $it }
function Get-ActiveList { if ($script:viewMode -eq 'grid') { return $gridList } else { return $list } }
function Get-Selected {
    if ($script:viewMode -eq 'grid') { if ($script:gridHit) { return $script:gridHit.It }; return $null }
    $s = $list.SelectedItem; if ($s) { return $s.It }; return $null
}
function Get-SelectedAll {
    if ($script:viewMode -eq 'grid') { if ($script:gridHit) { return @($script:gridHit.It) }; return @() }
    return @($list.SelectedItems | ForEach-Object { $_.It })
}
function Open-Selected {
    $all = Get-SelectedAll
    if ($all.Count -eq 0 -and $list.Items.Count -gt 0) { $all = @($list.Items[0].It) }
    foreach ($it in ($all | Select-Object -First 10)) { Open-Item $it }
}
function Copy-Text([string]$t, [string]$msg) {
    try { [System.Windows.Clipboard]::SetText($t); Show-Status $msg } catch { Show-Status 'Could not copy to clipboard' }
}
function Copy-Paths {
    $all = Get-SelectedAll
    if ($all.Count -eq 0) { return }
    Copy-Text (($all | ForEach-Object { $_.FullName }) -join [Environment]::NewLine) $(if ($all.Count -eq 1) { 'Path copied' } else { '{0} paths copied' -f $all.Count })
}

function Save-Cfg {
    try {
        if ($script:idxMode -eq 'pc') { $cfg['pcdrive'] = $txtDrive.Text } else { $cfg['drive'] = $txtDrive.Text }
        $cfg['pcskip'] = $(if ($chkSkipSys.IsChecked) { '1' } else { '0' })
        $cfg['pcdocs'] = $(if ($chkDocsOnly.IsChecked) { '1' } else { '0' })
        $cfg['depth'] = $txtDepth.Text
        $cfg['cols2'] = [US.Cols]::Spec($gv)
        $cfg['zoom']  = $script:zoom.ToString($inv)
        $cfg['scope'] = $(if ($script:scopeName -and $script:scopePath) { 'all' } elseif ($script:scopeName) { 'name' } else { 'path' })
        $cfg['sort']  = [string]$searcher.SortCol + ',' + $(if ($searcher.SortDesc) { '1' } else { '0' })
        $cfg['types'] = $script:typeSel -join ';'
        $cfg['years'] = $script:years -join ';'
        $cfg['kind']  = $(if ($rbFiles.IsChecked) { 'files' } elseif ($rbDirs.IsChecked) { 'dirs' } else { 'all' })
        if (-not (Test-Path -LiteralPath $cfgDir)) { [void](New-Item -ItemType Directory -Path $cfgDir -Force) }
        Set-Content -LiteralPath $cfgPath -Value @($cfg.Keys | Sort-Object | ForEach-Object { $_ + '=' + $cfg[$_] }) -Encoding UTF8
    } catch { }
}
# ---------------- loading + sharing the index ----------------
# default shared folder: where the app lives on the common drive, else <common drive>\UniversalSearch
function Get-DefaultShared {
    if ($appOnNetwork) { return $appDir }
    $first = @(([string]$cfg['drive']) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $r = if ($first.Count -gt 0) { Get-DriveRoot $first[0] } else { $null }
    if ($r) { return [IO.Path]::Combine($r, 'UniversalSearch') }
    return $appDir
}
function Set-SharedPaths {
    $script:sharedDir = $(if ($cfg['shared']) { [string]$cfg['shared'] } else { Get-DefaultShared })
    $script:masterPath = [IO.Path]::Combine($script:sharedDir, 'index.usx')
    $script:lockPath = [IO.Path]::Combine($script:sharedDir, 'index.lock')
    # shared folder on this PC's own disk (e.g. testing): use it directly, no copy needed
    $script:masterLocal = Test-LocalPath $script:sharedDir
    $script:commonPath = $(if ($script:masterLocal) { $script:masterPath } else { $cacheCommon })
}
function Start-Load([string]$path, [string]$kind) {
    $ld = New-Object US.Loader
    $ld.Start($path)
    [void]$script:loads.Add(@{ L = $ld; Kind = $kind; Path = $path })
    $poll.Start()
}
function Set-Combined {
    $script:idx = [US.IndexData]::Merge($script:nasIdx, $script:pcIdx)
    $searcher.SetIndex($script:idx)
    Update-Info
    [void](Test-Inputs $false)
    if ($searchBox.Text.Trim().Length -gt 0) { Update-List }
}
# Check the shared index in the background: reads only its date and size; copies it only when it changed.
function Start-Sync {
    if ($script:masterLocal -or $script:syncJob -or $script:indexer) { return }
    if (@($script:loads | Where-Object { $_.Kind -eq 'download' }).Count -gt 0) { return }
    $script:lastSync = [DateTime]::Now
    $script:syncJob = [US.SyncJob]::Start($script:masterPath, $cacheCommon, [string]$cfg['nasstamp'])
    $poll.Start()
}
function Remove-File([string]$p) { try { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } } catch { } }
function Show-NoIndex([string]$why) {
    if (-not $script:legacyTried) {
        # an old index.csv from the previous version is still usable until the first update
        $script:legacyTried = $true
        foreach ($p in @([string]$cfg['index'], $csvPath)) {
            if ($p -and $p -like '*.csv' -and (Test-Path -LiteralPath $p -PathType Leaf)) { Start-Load $p 'nas'; return }
        }
    }
    if ($script:nasIdx) { return }
    if ($script:pcIdx -or @($script:loads | Where-Object { $_.Kind -eq 'pc' }).Count -gt 0) { if ($why) { Show-Status $why }; return }
    Set-InfoText 'No index yet' 'Folder depth -' 'Last index updated -'
    $lblStatus.Text = $(if ($why) { $why } else { 'No search index yet. Click "Update index" and then "Start indexing".' })
}
function Complete-Load($e) {
    $ld = $e.L
    if (-not $ld.Error) { $lblStatus.Text = '' }
    switch ($e.Kind) {
        'pc' {
            if ($ld.Error) { Show-Status 'The This PC index could not be read. Update it again under "Update index".'; return }
            $script:pcIdx = $ld.Result; $script:pcMeta = $ld.Meta
        }
        'download' {
            if ($ld.Error) { Remove-File $e.Path; Show-Status 'The new index from the common drive could not be read - the current one is kept.'; return }
            try { [US.IndexFile]::Replace($e.Path, $cacheCommon); $cfg['nasstamp'] = $e.Stamp; Save-Cfg } catch { }
            $had = [bool]$script:nasIdx
            $script:nasIdx = $ld.Result; $script:nasMeta = $ld.Meta; $script:nasFile = $cacheCommon
            if ($had) { Show-Status ('New index received from the common drive (updated ' + (Format-When (Get-MetaTime $ld.Meta $null)) + ')') }
        }
        default {
            if ($ld.Error) {
                if ($script:syncAfterLoad) { $script:syncAfterLoad = $false; Start-Sync }
                elseif (-not $script:nasIdx) { Show-NoIndex 'The search index could not be loaded. Click "Update index" to build it.' }
                return
            }
            $script:nasIdx = $ld.Result; $script:nasMeta = $ld.Meta; $script:nasFile = $e.Path
            if ($script:syncAfterLoad) { $script:syncAfterLoad = $false; Start-Sync }
        }
    }
    Set-Combined
}
function Complete-Sync($sj) {
    switch ($sj.State) {
        'copied' {
            $ld = New-Object US.Loader
            $ld.Start($sj.Download)
            [void]$script:loads.Add(@{ L = $ld; Kind = 'download'; Path = $sj.Download; Stamp = $sj.Stamp })
        }
        'missing' { if (-not $script:nasIdx) { Show-NoIndex '' } }
        'error'   { if (-not $script:nasIdx) { Show-NoIndex ('The common drive could not be reached: ' + $sj.Error) } }
    }
}

# only one PC updates the common drive index at a time
function Get-LockInfo {
    try {
        if (-not (Test-Path -LiteralPath $script:lockPath -PathType Leaf)) { return $null }
        $li = Get-Item -LiteralPath $script:lockPath
        if (([DateTime]::Now - $li.LastWriteTime).TotalHours -gt 6) { return $null }
        $who = ([string](Get-Content -LiteralPath $script:lockPath -TotalCount 1)).Split('|')
        if ($who[0] -eq $env:COMPUTERNAME) { return $null }
        return ('The index is being updated right now on ' + $who[0] + ' (started ' + $li.LastWriteTime.ToString('hh:mm tt', $inv) + '). Please wait - every PC gets the new index automatically when it is ready.')
    } catch { return $null }
}
function Set-Lock { try { Set-Content -LiteralPath $script:lockPath -Value ($env:COMPUTERNAME + '|' + $env:USERNAME) -Encoding ASCII; $script:lockSet = $true } catch { } }
function Remove-Lock { if ($script:lockSet) { $script:lockSet = $false; Remove-File $script:lockPath } }

# ---------------- confirmation box ----------------
function Show-Confirm([string]$title, [string]$msg, [string]$okText, [scriptblock]$action, [string]$glyph) {
    $dlgTitle.Text = $title; $dlgMsg.Text = $msg; $dlgOk.Content = $okText; $dlgIco.Text = $glyph
    $script:dlgAction = $action
    $dlgOverlay.Visibility = 'Visible'
    [void]$dlgOk.Focus()
}
function Close-Confirm([bool]$ok) {
    $dlgOverlay.Visibility = 'Collapsed'
    $a = $script:dlgAction; $script:dlgAction = $null
    if ($ok -and $a) { & $a }
}

function Set-Zoom([double]$z) {
    $z = [Math]::Round([Math]::Max(0.8, [Math]::Min(1.6, $z)), 2)
    $script:zoom = $z
    $zoomTf.ScaleX = $z; $zoomTf.ScaleY = $z
}

# Standard, visible-to-security launch: powershell.exe -File <this script>. The console closes itself at start-up.
# conhost.exe = the classic Windows console. Using it directly avoids Windows Terminal, whose window would stay open.
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$conExe = Join-Path $env:SystemRoot 'System32\conhost.exe'
if (-not (Test-Path -LiteralPath $conExe)) { $conExe = $null }
function Get-LaunchArgs {
    if (-not $SelfPath) { return $null }
    $a = '-NoProfile -ExecutionPolicy Bypass -File "' + $SelfPath + '"'
    if ($conExe) { return '"' + $psExe + '" ' + $a } else { return $a }
}
function Get-LaunchTarget { if ($conExe) { return $conExe } else { return $psExe } }
function Update-Shortcut {
    try {
        $la = Get-LaunchArgs
        if (-not $la) { return }
        $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Universal Search.lnk'
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnk)
        if ((Test-Path -LiteralPath $lnk) -and $sc.TargetPath -eq (Get-LaunchTarget) -and $sc.Arguments -eq $la -and $sc.IconLocation -like ($icoPath + '*') -and $cfg['lnkid'] -eq ($AppId + '3')) { return }
        $sc.TargetPath = Get-LaunchTarget
        $sc.Arguments = $la
        $sc.WorkingDirectory = Split-Path -Parent $SelfPath
        $sc.IconLocation = $icoPath + ',0'
        $sc.Description = 'Universal Search System'
        $sc.WindowStyle = 7
        $sc.Save()
        if ([US.Ui]::SetLinkAppId($lnk, $AppId)) { $cfg['lnkid'] = $AppId + '3'; Save-Cfg }
    } catch { }
}

# ---------------- sorting & filters (column title menus + chips) ----------------
function Get-SortLabel {
    $c = $searcher.SortCol; $d = $searcher.SortDesc
    switch ($c) {
        1 { if ($d) { 'Name Z-A' } else { 'Name A-Z' } }
        2 { if ($d) { 'Path Z-A' } else { 'Path A-Z' } }
        3 { if ($d) { 'Largest first' } else { 'Smallest first' } }
        4 { if ($d) { 'Newest first' } else { 'Oldest first' } }
        5 { if ($d) { 'Type Z-A' } else { 'Type A-Z' } }
        6 { if ($d) { 'Full path Z-A' } else { 'Full path A-Z' } }
        9 { 'Best match' }
        default { '' }
    }
}
function Update-Headers {
    $up = [string][char]0x2191; $dn = [string][char]0x2193
    for ($i = 0; $i -lt [US.Cols]::Titles.Length; $i++) {
        $t = [US.Cols]::Titles[$i]
        if ($searcher.SortCol -eq ($i + 1)) { $t += '  ' + $(if ($searcher.SortDesc) { $dn } else { $up }) }
        if ($i -eq 4 -and $script:typeSel.Count -gt 0) { $t += ':  ' + ($script:typeSel -join ', ') }
        if ($i -eq 3 -and $script:years.Count -gt 0) { $t += ':  ' + (Get-YearText) }
        [US.Cols]::All[$i].Header = $t
    }
}
function Add-Chip([string]$text, [string]$tag) {
    $b = New-Object System.Windows.Controls.Button
    $b.Style = $chipStyle
    $b.Padding = '10,3'
    $b.Background = '#DBEAFE'; $b.BorderBrush = '#93C5FD'; $b.Foreground = '#1E40AF'
    $b.Tag = $tag
    $b.ToolTip = 'Click to remove'
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    $t1 = New-Object System.Windows.Controls.TextBlock
    $t1.Text = $text; $t1.FontSize = 11.5; $t1.VerticalAlignment = 'Center'
    $t2 = New-Object System.Windows.Controls.TextBlock
    $t2.Text = [string][char]0xE711; $t2.FontFamily = 'Segoe MDL2 Assets'; $t2.FontSize = 8; $t2.Margin = '8,1,0,0'; $t2.VerticalAlignment = 'Center'
    [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2)
    $b.Content = $sp
    $b.Add_Click({
        param($s, $e)
        switch ($s.Tag) {
            'sort' { Set-Sort 0 $false }
            'type' { $script:typeSel.Clear(); Update-Filters }
            'year' { $script:years.Clear(); Update-Filters }
        }
    })
    [void]$chipBar.Children.Add($b)
}
function Update-Chips {
    $chipBar.Children.Clear()
    $sl = Get-SortLabel
    if ($sl) { Add-Chip ('Sorted: ' + $sl) 'sort' }
    $other = @($script:typeSel | Where-Object { @('PDF', 'Excel', 'Word', 'Images') -notcontains $_ })
    if ($other.Count -gt 0) { Add-Chip ('Type: ' + ($script:typeSel -join ', ')) 'type' }
    if ($script:years.Count -gt 0) { Add-Chip ('Year: ' + (Get-YearText)) 'year' }
}
function Set-Sort([int]$col, [bool]$desc) {
    if ($col -eq 0 -or $col -eq 9) { $desc = $false }
    $searcher.SortCol = $col; $searcher.SortDesc = $desc
    Update-Headers; Update-Chips; Save-Cfg
    if ($searcher.Current) { [void]$searcher.Run($searcher.Current) }
}
function Get-YearText { return (@($script:years | Sort-Object -Descending) -join ', ') }
function Update-Filters { Update-Headers; Update-Chips; Sync-Toggles; Update-List; Save-Cfg }
function Test-FiltersOn { return ($script:typeSel.Count -gt 0 -or $script:years.Count -gt 0 -or -not $rbAll.IsChecked -or -not $script:scopePath) }
function Reset-Filters {
    $script:typeSel.Clear(); $script:years.Clear()
    $script:scopeName = $true; $script:scopePath = $true
    $rbAll.IsChecked = $true
    Update-Filters
    Show-Status 'Filters reset'
}
# the sort order and filters from last time
function Restore-View {
    $p = ([string]$cfg['sort']).Split(',')
    $c = 0; [void][int]::TryParse($p[0], [ref]$c)
    $searcher.SortCol = $c
    $searcher.SortDesc = ($p.Count -gt 1 -and $p[1] -eq '1' -and $c -ne 0 -and $c -ne 9)
    switch ([string]$cfg['kind']) { 'files' { $rbFiles.IsChecked = $true } 'dirs' { $rbDirs.IsChecked = $true } }
    foreach ($t in ([string]$cfg['types']).Split(';')) { if ($t -and $typeDefs.Contains($t) -and -not ($script:typeSel -contains $t)) { [void]$script:typeSel.Add($t) } }
    foreach ($y in ([string]$cfg['years']).Split(';')) { $n = 0; if ([int]::TryParse($y, [ref]$n) -and $n -gt 1900) { [void]$script:years.Add($n) } }
    Update-Headers; Update-Chips; Sync-Toggles
}

$hdrClick = {
    param($s, $e)
    $p = ([string]$s.Tag).Split(',')
    switch ($p[0]) {
        's' { Set-Sort ([int]$p[1]) ($p[2] -eq '1') }
        'y' {
            # years: pick one or several; "All years" clears the choice
            $m = $s.Parent
            $script:years.Clear()
            if ($p[1] -ne '0') {
                foreach ($x in $m.Items) {
                    if ($x -is [System.Windows.Controls.MenuItem] -and ([string]$x.Tag).StartsWith('y,') -and $x.Tag -ne 'y,0' -and $x.IsChecked) { [void]$script:years.Add([int]([string]$x.Tag).Substring(2)) }
                }
            }
            foreach ($x in $m.Items) {
                if ($x -is [System.Windows.Controls.MenuItem] -and ([string]$x.Tag).StartsWith('y,')) {
                    if ($x.Tag -eq 'y,0') { $x.IsChecked = ($script:years.Count -eq 0) } elseif ($script:years.Count -eq 0) { $x.IsChecked = $false }
                }
            }
            Update-Filters
        }
        't' {
            $m = $s.Parent
            if ($p[1] -eq '*') {
                $script:typeSel.Clear()
                foreach ($x in $m.Items) { if ($x -is [System.Windows.Controls.MenuItem] -and ([string]$x.Tag).StartsWith('t,')) { $x.IsChecked = ($x.Tag -eq 't,*') } }
            } else {
                $script:typeSel.Clear()
                foreach ($x in $m.Items) {
                    if ($x -is [System.Windows.Controls.MenuItem] -and ([string]$x.Tag).StartsWith('t,') -and $x.Tag -ne 't,*' -and $x.IsChecked) { [void]$script:typeSel.Add($x.Header) }
                }
                foreach ($x in $m.Items) { if ($x -is [System.Windows.Controls.MenuItem] -and $x.Tag -eq 't,*') { $x.IsChecked = ($script:typeSel.Count -eq 0) } }
            }
            Update-Filters
        }
    }
}
function Add-HdrItem($m, [string]$text, [string]$tag, [bool]$checked, [bool]$toggle = $false) {
    $mi = New-Mi $text $tag
    $mi.IsChecked = $checked
    if ($toggle) { $mi.IsCheckable = $true; $mi.StaysOpenOnClick = $true }
    $mi.Add_Click($hdrClick)
    [void]$m.Items.Add($mi)
}
function Show-HeaderMenu([int]$i, $target) {
    $m = New-Menu
    $sc = $searcher.SortCol; $sd = $searcher.SortDesc
    $col = $i + 1
    switch ($i) {
        2 { Add-HdrItem $m 'Largest first' "s,3,1" ($sc -eq 3 -and $sd); Add-HdrItem $m 'Smallest first' "s,3,0" ($sc -eq 3 -and -not $sd) }
        3 {
            Add-HdrItem $m 'Newest first' "s,4,1" ($sc -eq 4 -and $sd); Add-HdrItem $m 'Oldest first' "s,4,0" ($sc -eq 4 -and -not $sd)
            [void]$m.Items.Add((New-Sep)); [void]$m.Items.Add((New-MenuLabel 'MODIFIED IN'))
            Add-HdrItem $m 'All years' 'y,0' ($script:years.Count -eq 0)
            $y0 = (Get-Date).Year
            for ($y = $y0; $y -ge $y0 - 3; $y--) { Add-HdrItem $m ($(if ($y -eq $y0) { "$y  (this year)" } else { "$y" })) "y,$y" ($script:years -contains $y) $true }
        }
        default {
            Add-HdrItem $m ('Sort A ' + $arrow + ' Z') "s,$col,0" ($sc -eq $col -and -not $sd)
            Add-HdrItem $m ('Sort Z ' + $arrow + ' A') "s,$col,1" ($sc -eq $col -and $sd)
        }
    }
    if ($i -eq 4) {
        [void]$m.Items.Add((New-Sep)); [void]$m.Items.Add((New-MenuLabel 'SHOW FILE TYPES'))
        Add-HdrItem $m 'All types' 't,*' ($script:typeSel.Count -eq 0)
        foreach ($k in $typeDefs.Keys) { Add-HdrItem $m $k "t,$k" ($script:typeSel -contains $k) $true }
    }
    [void]$m.Items.Add((New-Sep))
    Add-HdrItem $m 'Default order (no sorting)' 's,0,0' ($sc -eq 0)
    Add-HdrItem $m 'Best match first' 's,9,0' ($sc -eq 9)
    $m.PlacementTarget = $target; $m.Placement = 'Bottom'; $m.IsOpen = $true
}
$list.AddHandler([System.Windows.Controls.GridViewColumnHeader]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($s, $e)
    $h = $e.OriginalSource -as [System.Windows.Controls.GridViewColumnHeader]
    if (-not $h -or -not $h.Column) { return }
    $i = [US.Cols]::IndexOf($h.Column)
    if ($i -ge 0) { Open-HeaderMenuLater $i $h }
})
# open the menu after the click has fully finished - otherwise it closes again immediately
function Open-HeaderMenuLater([int]$i, $h) {
    $script:hdrPending = @($i, $h)
    [void]$w.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ApplicationIdle, [Action]{
        $p = $script:hdrPending; $script:hdrPending = $null
        if ($p) { Show-HeaderMenu $p[0] $p[1] }
    })
}
$list.Add_PreviewMouseRightButtonUp({
    $d = $_.OriginalSource -as [System.Windows.DependencyObject]
    while ($d -and -not ($d -is [System.Windows.Controls.GridViewColumnHeader]) -and -not ($d -is [System.Windows.Controls.ListViewItem])) {
        $d = if ($d -is [System.Windows.Media.Visual]) { [System.Windows.Media.VisualTreeHelper]::GetParent($d) } else { $null }
    }
    if ($d -is [System.Windows.Controls.GridViewColumnHeader]) {
        $_.Handled = $true
        $i = if ($d.Column) { [US.Cols]::IndexOf($d.Column) } else { -1 }
        if ($i -ge 0) { Open-HeaderMenuLater $i $d } else { $colMenu.PlacementTarget = $d; $colMenu.Placement = 'Bottom'; $colMenu.IsOpen = $true }
    }
})

# ---------------- index panel validation ----------------
function Set-V($tb, [string]$msg, [string]$level) {
    if (-not $msg) { $tb.Visibility = 'Collapsed'; return }
    $tb.Text = $msg
    $tb.Foreground = $(if ($level -eq 'err') { '#DC2626' } else { '#B45309' })
    $tb.Visibility = 'Visible'
}
function Test-Inputs([bool]$checkPaths) {
    $ok = $true
    # drive / folder
    $roots = @($txtDrive.Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $dm = ''
    if ($roots.Count -eq 0) { $dm = 'Enter a drive or folder, for example W:\ or \\NAS\share' }
    else {
        foreach ($r in $roots) {
            if ($r -notmatch '^[A-Za-z]:(\\.*)?$' -and $r -notmatch '^\\\\[^\\]+\\[^\\]+') { $dm = 'Not a valid path: ' + $r + '   (use W:\folder or \\server\share)'; break }
            if ($checkPaths) {
                $rp = $r; if ($rp -notmatch '\\$') { $rp += '\' }
                if (-not (Test-Path -LiteralPath $rp)) { $dm = 'Not found or not connected: ' + $r; break }
            }
        }
    }
    if ($dm) { $ok = $false }
    Set-V $vDrive $dm 'err'
    # folder depth
    $dt = $txtDepth.Text.Trim(); $n = 0; $lm = ''
    if ($dt -ne '') {
        if (-not [int]::TryParse($dt, [ref]$n) -or $n -le 0) { $lm = 'Folder depth must be a whole number (1-60), or empty for full depth.' }
        elseif ($n -gt 60) { $lm = 'Too large. Shipboard folders are rarely deeper than 15-20 levels - use 60 or less, or leave empty for full depth.' }
        else {
            $have = Get-IndexDepth
            $sameRoots = ($script:idxMode -eq 'nas') -and ((Get-RootsText $txtDrive.Text) -eq (Get-RootsText (Get-NasRoots)))
            if ($sameRoots -and $have -gt 0 -and $n -lt $have) { $lm = ('Not allowed: the current index already has folder depth {0}. Enter {0} or more, or leave empty - a smaller value would shrink the index.' -f $have) }
        }
    }
    if ($lm) { $ok = $false }
    Set-V $vDepth $lm 'err'
    # threads
    $tt = $txtThreads.Text.Trim(); $tm = ''; $lvl = 'err'
    if ($tt -ne '') {
        if (-not [int]::TryParse($tt, [ref]$n) -or $n -lt 1) { $tm = 'Threads must be a whole number from 1 to 64.' }
        elseif ($n -gt 64) { $tm = 'Maximum is 64 threads.' }
        elseif ($n -gt 32 -and $script:idxMode -eq 'pc') { $tm = 'High value: this PC may become slow while indexing. 8-16 is enough for a local disk.'; $lvl = 'warn' }
        elseif ($n -gt 32) { $tm = 'High value: this can slow the NAS for everyone else. 16 is best by day, up to 32 at night.'; $lvl = 'warn' }
        elseif ($n -lt 4 -and $script:idxMode -eq 'nas') { $tm = 'Very low: scanning a large NAS will be slow. 16 is recommended.'; $lvl = 'warn' }
    }
    if ($tm -and $lvl -eq 'err') { $ok = $false }
    Set-V $vThreads $tm $lvl
    if (-not $script:indexer) { $btnStart.IsEnabled = $ok }
    return $ok
}
foreach ($tb in @($txtDrive, $txtDepth, $txtThreads)) { $tb.Add_TextChanged({ [void](Test-Inputs $false) }) }

# ---------------- help text ----------------
function Add-HelpHead([string]$text) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text; $t.FontSize = 13; $t.FontWeight = 'SemiBold'; $t.Foreground = '#1E3A8A'; $t.Margin = '0,14,0,6'
    [void]$helpBody.Children.Add($t)
}
function Add-HelpRow([string]$key, [string]$text) {
    # key = short label shown in a grey badge (e.g. Enter); empty key = bullet point
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = '0,0,0,7'
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = $(if ($key) { '112' } else { '18' })
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
    if ($key) {
        $b = New-Object System.Windows.Controls.Border
        $b.Background = '#EEF2F7'; $b.BorderBrush = '#D5DDE8'; $b.BorderThickness = '1'; $b.CornerRadius = '5'; $b.Padding = '7,1'
        $b.HorizontalAlignment = 'Left'; $b.VerticalAlignment = 'Top'
        $k = New-Object System.Windows.Controls.TextBlock
        $k.Text = $key; $k.FontSize = 11.5; $k.FontWeight = 'SemiBold'; $k.Foreground = '#334155'
        $b.Child = $k
        [void]$g.Children.Add($b)
    } else {
        $d = New-Object System.Windows.Controls.TextBlock
        $d.Text = $bullet; $d.Foreground = '#2563EB'; $d.FontSize = 13
        [void]$g.Children.Add($d)
    }
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text; $t.TextWrapping = 'Wrap'; $t.FontSize = 12.5; $t.Foreground = '#334155'; $t.Margin = '0,1,0,0'
    [System.Windows.Controls.Grid]::SetColumn($t, 1)
    [void]$g.Children.Add($t)
    [void]$helpBody.Children.Add($g)
}
Add-HelpHead 'Searching'
Add-HelpRow '' 'Type part of a file or folder name. Results appear as you type.'
Add-HelpRow '' 'Press Space twice anywhere to jump back to the search box.'
Add-HelpHead 'Mouse'
Add-HelpRow 'Click name' 'Opens the file.'
Add-HelpRow 'Click path' 'Opens the folder with the file selected.'
Add-HelpRow 'Right-click' 'More actions: copy path, open with, properties.'
Add-HelpRow 'Drag rows' 'Copies the files into Explorer or Outlook.'
Add-HelpHead 'Keyboard'
Add-HelpRow 'Enter' 'Open the selected file.'
Add-HelpRow 'Ctrl + Enter' 'Open its folder.'
Add-HelpRow 'Ctrl + C' 'Copy the full path.'
Add-HelpRow 'Esc' 'Back to search / clear.'
Add-HelpRow 'Ctrl + wheel' 'Make the list bigger or smaller.'
Add-HelpHead 'Images'
Add-HelpRow 'Grid view' 'Choose Images (or type .jpg, .png ...) and I show pictures as thumbnails. Use List / Grid at the top right to switch.'
Add-HelpRow 'Hover' 'Shows the name, full path and date modified.'
Add-HelpRow 'Click' 'Opens the picture.'
Add-HelpRow 'Right-click' 'Open this path (folder), copy path, properties.'
Add-HelpRow '' 'Many pictures? I show 120 at a time - scroll down for more.'
Add-HelpHead 'Sorting and filters'
Add-HelpRow '' 'Click a column title (Name, Size, Date modified...) to sort.'
Add-HelpRow '' 'Date modified: pick one or more years. Type: pick more file types.'
Add-HelpRow '' 'Drag a column edge to make it wider or narrower.'
Add-HelpHead 'Tips'
Add-HelpRow '"manuals"' 'Text in quotes is matched exactly as typed, spaces included.'
Add-HelpRow '" tro "' 'Spaces inside the quotes find TRO as a separate word - not inside "control" or "petrol".'
Add-HelpRow 'pump*manual' '* stands for any text: finds names that contain both pump and manual.'
Add-HelpRow '*.pdf' 'Only files of that type (same as ext:pdf).'
Add-HelpRow '-old' 'Leave out results containing "old".'
Add-HelpRow 'ext:dwg' 'Only one file type (same as *.dwg).'
Add-HelpHead 'The index'
Add-HelpRow '' 'Search uses an index, not the live drive. New files appear after the next index update.'
Add-HelpRow '' 'The common drive index is shared: when anyone updates it, every PC gets it automatically (checked at start and every 30 minutes).'
Add-HelpRow '' 'This PC: in Update index, choose This PC to also find documents on your own computer. That index stays on your PC.'
Add-HelpHead 'About'
$aboutSeed = @(@(60,61,26,52,50,65,22,39,54,69,39,48,45,74), @(64,110,74,104,104,73,95,104))
$aboutTag = @($aboutSeed | ForEach-Object { $v = $_; -join (0..($v.Count - 1) | ForEach-Object { [char](($v[$_] - $_) -bxor (23, 5, 41, 17)[$_ % 4]) }) })
$about = New-Object System.Windows.Controls.Border
$about.Background = '#F8FAFC'; $about.BorderBrush = '#E2E8F0'; $about.BorderThickness = '1'; $about.CornerRadius = '12'; $about.Padding = '14,12'; $about.Margin = '0,2,0,4'
$aboutSp = New-Object System.Windows.Controls.StackPanel
$t = New-Object System.Windows.Controls.TextBlock
$t.Text = 'This app is developed by ' + $DeveloperName + '.'; $t.FontSize = 12.5; $t.FontWeight = 'SemiBold'; $t.Foreground = '#1E3A8A'
[void]$aboutSp.Children.Add($t)
$t = New-Object System.Windows.Controls.TextBlock
$t.Text = 'Need help, have a suggestion or some feedback? Feel free to message me on ' + $aboutTag[1] + ':'; $t.FontSize = 12; $t.Foreground = '#475569'; $t.TextWrapping = 'Wrap'; $t.Margin = '0,4,0,8'
[void]$aboutSp.Children.Add($t)
$aboutBtn = New-Object System.Windows.Controls.Button
$aboutBtn.Style = $w.FindResource('ChipBtn'); $aboutBtn.HorizontalAlignment = 'Left'; $aboutBtn.Margin = '0'; $aboutBtn.Padding = '12,5'
$aboutBtn.Background = '#DCFCE7'; $aboutBtn.BorderBrush = '#86EFAC'; $aboutBtn.Foreground = '#166534'; $aboutBtn.ToolTip = 'Click to copy'
$sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
$t = New-Object System.Windows.Controls.TextBlock; $t.Text = [string][char]0xE717; $t.FontFamily = 'Segoe MDL2 Assets'; $t.FontSize = 12; $t.Margin = '0,1,8,0'; $t.VerticalAlignment = 'Center'
[void]$sp.Children.Add($t)
$t = New-Object System.Windows.Controls.TextBlock; $t.Text = $aboutTag[0]; $t.FontSize = 13; $t.FontWeight = 'SemiBold'; $t.VerticalAlignment = 'Center'
[void]$sp.Children.Add($t)
$aboutBtn.Content = $sp
$aboutBtn.Add_Click({ Copy-Text $aboutTag[0] 'Copied' })
[void]$aboutSp.Children.Add($aboutBtn)
$about.Child = $aboutSp
[void]$helpBody.Children.Add($about)

# ---------------- "take me to another PC" ----------------
function Add-ShareHead([string]$text) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text; $t.FontSize = 10.5; $t.FontWeight = 'Bold'; $t.Foreground = '#64748B'; $t.Margin = '0,18,0,8'
    [void]$shareBody.Children.Add($t)
}
function Add-Step([int]$n, [string]$text, [string]$strong = '') {
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = '0,0,0,9'
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '34'
    $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $b = New-Object System.Windows.Controls.Border
    $b.Width = 22; $b.Height = 22; $b.CornerRadius = '11'; $b.Background = '#DBEAFE'; $b.HorizontalAlignment = 'Left'; $b.VerticalAlignment = 'Top'
    $k = New-Object System.Windows.Controls.TextBlock
    $k.Text = [string]$n; $k.FontSize = 11.5; $k.FontWeight = 'Bold'; $k.Foreground = '#1D4ED8'; $k.HorizontalAlignment = 'Center'; $k.VerticalAlignment = 'Center'
    $b.Child = $k
    [void]$g.Children.Add($b)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.TextWrapping = 'Wrap'; $t.FontSize = 12.5; $t.Foreground = '#334155'; $t.Margin = '0,2,0,0'; $t.LineHeight = 18
    $t.Inlines.Add((New-Object System.Windows.Documents.Run $text))
    if ($strong) {
        $r = New-Object System.Windows.Documents.Run (' ' + $strong)
        $r.FontWeight = 'SemiBold'; $r.Foreground = '#1E3A8A'
        $t.Inlines.Add($r)
    }
    [System.Windows.Controls.Grid]::SetColumn($t, 1)
    [void]$g.Children.Add($t)
    [void]$shareBody.Children.Add($g)
}
function Build-SharePanel {
    $shareBody.Children.Clear()
    Add-ShareHead 'ON THE SHIP NETWORK  (RECOMMENDED)'
    Add-Step 1 'On the other PC, open the shared folder on the common drive:' $script:sharedDir
    Add-Step 2 'Double-click UniversalSearch.cmd. I put my own icon on the desktop.'
    Add-Step 3 'Open me from that icon, right-click my icon on the taskbar and choose Pin. From then on, my updates and the latest index reach that PC by themselves.'
    Add-ShareHead 'ANY OTHER COMPUTER'
    Add-Step 1 'Click Download zip below and save me, for example on the Desktop.'
    Add-Step 2 'Copy the zip to the other computer - USB stick, e-mail or a network folder.'
    Add-Step 3 'Right-click the zip and choose Extract All. Do not start me from inside the zip.'
    Add-Step 4 'Open the extracted folder and double-click' 'UniversalSearch.cmd.'
    Add-Step 5 'Click Update index, then Start indexing, so I can build my index on that computer.'
    $n = New-Object System.Windows.Controls.TextBlock
    $n.Text = 'Keep my three files together: UniversalSearch.cmd, UniversalSearch.ps1 and UniversalSearch.ico. I work on Windows 10 and 11.'
    $n.FontSize = 11.5; $n.Foreground = '#64748B'; $n.TextWrapping = 'Wrap'; $n.Margin = '0,6,0,0'
    [void]$shareBody.Children.Add($n)
}
$launcherCmd = "@echo off`r`nrem Universal Search System - double-click to start (UniversalSearch.ps1 must be in the same folder)`r`n" +
    "if exist `"%SystemRoot%\System32\conhost.exe`" (`r`n  start `"`" /min `"%SystemRoot%\System32\conhost.exe`" powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0UniversalSearch.ps1`"`r`n" +
    ") else (`r`n  start `"`" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0UniversalSearch.ps1`"`r`n)`r`n"
function Save-Zip {
    $zipMsg.Text = ''
    if (-not $SelfPath -or -not (Test-Path -LiteralPath $SelfPath)) { $zipMsg.Foreground = '#DC2626'; $zipMsg.Text = 'I could not find my own files.'; return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title = 'Where shall I save the zip?'
    $dlg.FileName = 'Universal Search.zip'
    $dlg.DefaultExt = '.zip'
    $dlg.Filter = 'Zip file (*.zip)|*.zip'
    $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($dlg.ShowDialog($w) -ne $true) { return }
    $tmp = Join-Path $env:TEMP ('UniversalSearch-zip-' + [Guid]::NewGuid().ToString('N'))
    try {
        [void](New-Item -ItemType Directory -Path $tmp -Force -ErrorAction Stop)
        Copy-Item -LiteralPath $SelfPath -Destination (Join-Path $tmp 'UniversalSearch.ps1') -ErrorAction Stop
        $cmdSrc = [IO.Path]::Combine($appDir, 'UniversalSearch.cmd')
        if (Test-Path -LiteralPath $cmdSrc) { Copy-Item -LiteralPath $cmdSrc -Destination (Join-Path $tmp 'UniversalSearch.cmd') -ErrorAction Stop }
        else { [IO.File]::WriteAllText((Join-Path $tmp 'UniversalSearch.cmd'), $launcherCmd, [Text.Encoding]::ASCII) }
        $icoSrc = [IO.Path]::Combine($appDir, 'UniversalSearch.ico')
        if (-not (Test-Path -LiteralPath $icoSrc)) { $icoSrc = $icoPath }
        if (Test-Path -LiteralPath $icoSrc) { Copy-Item -LiteralPath $icoSrc -Destination (Join-Path $tmp 'UniversalSearch.ico') -ErrorAction Stop }
        $readme = @(
            'UNIVERSAL SEARCH SYSTEM - how to start me on this computer',
            '',
            '1. Right-click the zip file and choose "Extract All" (do not start me from inside the zip).',
            '2. Open the extracted folder and double-click UniversalSearch.cmd.',
            '   I put my own icon on the desktop - use it next time, and pin me to the taskbar.',
            '3. Click "Update index", then "Start indexing", to build my index on this computer.',
            '',
            'Keep the three files together: UniversalSearch.cmd, UniversalSearch.ps1, UniversalSearch.ico.',
            'No installation and no admin rights needed. Works on Windows 10 and 11.',
            '',
            ('Help, suggestions or feedback: ' + $DeveloperName + ' - ' + $aboutTag[1] + ' ' + $aboutTag[0]))
        [IO.File]::WriteAllLines((Join-Path $tmp 'READ ME.txt'), [string[]]$readme)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if (Test-Path -LiteralPath $dlg.FileName) { Remove-Item -LiteralPath $dlg.FileName -Force -ErrorAction Stop }
        [IO.Compression.ZipFile]::CreateFromDirectory($tmp, $dlg.FileName)
        $zipMsg.Foreground = '#166534'
        $zipMsg.Text = 'Saved: ' + $dlg.FileName
        [void][US.Ui]::ShowInFolderAsync($dlg.FileName)
    } catch {
        $zipMsg.Foreground = '#DC2626'
        $zipMsg.Text = 'I could not save the zip: ' + $_.Exception.Message
    } finally {
        try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch { }
    }
}

# ---------------- timers ----------------
# every minute: "x min ago" and the greeting stay current
$clockTimer = New-Object System.Windows.Threading.DispatcherTimer
$clockTimer.Interval = [TimeSpan]::FromMinutes(1)
$clockTimer.Add_Tick({ Update-Greeting; if ($script:nasIdx -or $script:pcIdx) { Update-Info } })

$debounce = New-Object System.Windows.Threading.DispatcherTimer
$debounce.Interval = [TimeSpan]::FromMilliseconds(90)
$debounce.Add_Tick({ $debounce.Stop(); Update-List })
$gridSync = New-Object System.Windows.Threading.DispatcherTimer
$gridSync.Interval = [TimeSpan]::FromMilliseconds(120)
$gridSync.Add_Tick({
    if ($script:viewMode -eq 'grid') { Sync-Grid $false }
})
# near the bottom of the grid: add the next page of tiles
$gridList.AddHandler([System.Windows.Controls.ScrollViewer]::ScrollChangedEvent, [System.Windows.Controls.ScrollChangedEventHandler]{
    param($s, $e)
    if ($script:viewMode -ne 'grid' -or -not $gridPager.HasMore) { return }
    # only when the user scrolled (not when the list just grew), so pages are never added in a chain
    if ($e.VerticalChange -le 0 -or $e.ExtentHeightChange -ne 0) { return }
    if ($e.VerticalOffset + $e.ViewportHeight -ge $e.ExtentHeight - 300) {
        $gridPager.More($gridPageSize)
        Update-GridNote
    }
})
$gridSync.Start()

$statusTimer = New-Object System.Windows.Threading.DispatcherTimer
$statusTimer.Interval = [TimeSpan]::FromSeconds(5)
$statusTimer.Add_Tick({ $statusTimer.Stop(); $lblStatus.Text = '' })

$toastTimer = New-Object System.Windows.Threading.DispatcherTimer
$toastTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$toastTimer.Add_Tick({
    $el = ([DateTime]::Now - $script:toastStart).TotalSeconds
    $j = $script:toastJob
    if ($script:toastErr) { if ($el -gt 4) { Hide-Toast }; return }
    if ($j -and $j.Done -and $j.Error -and $openToast.Visibility -eq 'Visible') {
        $script:toastErr = $true; $script:toastStart = [DateTime]::Now
        $spinRot.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
        $spinner.Visibility = 'Collapsed'
        $toastText.Text = $j.Error
        Show-Status $j.Error
        return
    }
    # spinner shows at most 3 seconds; a late error still appears in the status bar
    if ($openToast.Visibility -eq 'Visible' -and ($el -gt 3 -or ($j -and $j.Done -and $el -gt 1.2))) {
        $spinRot.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
        $openToast.Visibility = 'Collapsed'
    }
    if ($openToast.Visibility -ne 'Visible') {
        if ($j -and $j.Done -and $j.Error) { Show-Status $j.Error; $toastTimer.Stop() }
        elseif (-not $j -or $j.Done -or $el -gt 30) { $toastTimer.Stop() }
    }
})

$poll = New-Object System.Windows.Threading.DispatcherTimer
$poll.Interval = [TimeSpan]::FromMilliseconds(200)
$poll.Add_Tick({
    for ($i = $script:loads.Count - 1; $i -ge 0; $i--) {
        $e = $script:loads[$i]
        if (-not $e.L.Done) {
            if ($e.Kind -ne 'pc' -and -not $script:nasIdx) { $hItems.Text = ('Loading index... {0:N0} items' -f $e.L.Count) }
            continue
        }
        $script:loads.RemoveAt($i)
        Complete-Load $e
    }
    if ($script:syncJob) {
        $sj = $script:syncJob
        if ($sj.Done) { $script:syncJob = $null; Complete-Sync $sj }
        elseif (-not $script:nasIdx) { $hItems.Text = ('Getting the index from the common drive... {0}%' -f $sj.Percent) }
    }
    if ($script:indexer) {
        $ix = $script:indexer
        if ($ix.Done) {
            $script:indexer = $null
            $btnStart.Content = 'Start indexing'
            Remove-Lock
            if ($ix.Error) { $lblProg.Text = 'Error: ' + $ix.Error }
            elseif ($ix.Result) {
                $sec = [Math]::Round($script:sw.Elapsed.TotalSeconds, 1)
                $msg = 'Done: {0:N0} items in {1} s.' -f $ix.Result.Items.Count, $sec
                if ($script:ixMode -eq 'pc') {
                    $script:pcIdx = $ix.Result; $script:pcMeta = $ix.Meta
                } else {
                    $script:nasIdx = $ix.Result; $script:nasMeta = $ix.Meta; $script:nasFile = $script:commonPath
                    if ($ix.PublishedStamp) { $cfg['nasstamp'] = $ix.PublishedStamp; Save-Cfg }
                    if ($ix.PublishError) { $msg += ' Saved on this PC only - the shared folder could not be written: ' + $ix.PublishError }
                    elseif (-not $script:masterLocal) { $msg += ' Every PC gets it automatically.' }
                }
                $lblProg.Text = $msg
                $lblStatus.Text = ''
                Set-Combined
                Show-Status ('Index updated - {0:N0} items' -f $ix.Result.Items.Count)
            } else { $lblProg.Text = 'Stopped. The old index was kept.' }
            [void](Test-Inputs $false)
        } else {
            if ($ix.Phase -eq 'Scanning') { $lblProg.Text = ('Scanning... {0:N0} items ({1} s)' -f $ix.Count, [int]$script:sw.Elapsed.TotalSeconds) }
            else { $lblProg.Text = $ix.Phase + '...' }
        }
    }
    if ($script:loads.Count -eq 0 -and -not $script:syncJob -and -not $script:indexer) { $poll.Stop() }
})

# re-check the shared index every 30 minutes, and when the window is used again after 10+ minutes
$syncTimer = New-Object System.Windows.Threading.DispatcherTimer
$syncTimer.Interval = [TimeSpan]::FromMinutes(30)
$syncTimer.Add_Tick({ Start-Sync })

# ---------------- search box events ----------------
$searchBox.Add_TextChanged({
    $t = $searchBox.Text
    if ($t.Length -gt 0 -and [char]::IsLower($t[0])) {
        # auto-capitalize the first letter (search itself ignores case)
        $ci = $searchBox.CaretIndex
        $searchBox.Text = [string][char]::ToUpper($t[0]) + $t.Substring(1)
        $searchBox.CaretIndex = $ci
        return
    }
    $hint.Visibility = if ($t.Length -eq 0) { 'Visible' } else { 'Collapsed' }
    $btnClear.Visibility = if ($t.Length -eq 0) { 'Collapsed' } else { 'Visible' }
    $debounce.Stop(); $debounce.Start()
})
$searchBox.Add_PreviewKeyDown({
    $k = $_.Key.ToString()
    $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    if ($k -eq 'Return') {
        $_.Handled = $true
        if ($debounce.IsEnabled) { $debounce.Stop(); Update-List; return }
        if ($ctrl) {
            $it = Get-Selected
            if (-not $it -and $list.Items.Count -gt 0) { $it = $list.Items[0].It }
            Show-InFolder $it
        } else { Open-Selected }
    } elseif ($k -eq 'Escape') {
        $_.Handled = $true
        $searchBox.Clear()
    } elseif ($k -eq 'Down') {
        if ($list.Items.Count -gt 0) {
            $_.Handled = $true
            if ($list.SelectedIndex -lt 0) { $list.SelectedIndex = 0 }
            $list.ScrollIntoView($list.SelectedItem)
            $list.UpdateLayout()
            $c = $list.ItemContainerGenerator.ContainerFromIndex($list.SelectedIndex)
            if ($c) { [void]$c.Focus() }
        }
    }
})
$btnClear.Add_Click({ $searchBox.Clear(); [void]$searchBox.Focus() })
$tbList.Add_Click({ $script:userChoseView = $true; Set-ViewMode 'list' })
$tbGrid.Add_Click({ $script:userChoseView = $true; Set-ViewMode 'grid' })
foreach ($rb in @($rbAll, $rbFiles, $rbDirs)) { $rb.Add_Checked({ Update-List }) }

# "Match in": All / Name only / Full path - several can be on, the last one can never be switched off
function Sync-Toggles {
    $tScopeAll.IsChecked = ($script:scopeName -and $script:scopePath)
    $tName.IsChecked = $script:scopeName
    $tPath.IsChecked = $script:scopePath
    $tTypeAll.IsChecked = ($script:typeSel.Count -eq 0)
    foreach ($t in @($tPdf, $tXls, $tDoc, $tImg)) { $t.IsChecked = ($script:typeSel -contains [string]$t.Tag) }
}
$tScopeAll.Add_Click({ $script:scopeName = $true; $script:scopePath = $true; Sync-Toggles; Update-List })
$tName.Add_Click({
    if ($script:scopeName -and $script:scopePath) { $script:scopePath = $false }
    elseif (-not $script:scopeName) { $script:scopeName = $true }
    Sync-Toggles; Update-List
})
$tPath.Add_Click({
    if ($script:scopeName -and $script:scopePath) { $script:scopeName = $false }
    elseif (-not $script:scopePath) { $script:scopePath = $true }
    Sync-Toggles; Update-List
})
# File type: All / PDF / Excel / Word / Images - pick one or several; none picked = All
$tTypeAll.Add_Click({ $script:typeSel.Clear(); Update-Filters })
foreach ($t in @($tPdf, $tXls, $tDoc, $tImg)) {
    $t.Add_Click({
        param($s, $e)
        $k = [string]$s.Tag
        if ($script:typeSel -contains $k) { $script:typeSel.Remove($k) } else { [void]$script:typeSel.Add($k) }
        Update-Filters
    })
}
Sync-Toggles

# ---------------- columns menu (also on right-click of the header row) ----------------
$colMenu = New-Menu
for ($i = 1; $i -lt [US.Cols]::Titles.Length; $i++) {
    $mi = New-Mi ([US.Cols]::Titles[$i]) ([int]$i)
    $mi.IsCheckable = $true
    $mi.StaysOpenOnClick = $true
    $mi.Add_Click({ param($s, $e) [US.Cols]::SetVisible($gv, [int]$s.Tag, [bool]$s.IsChecked) })
    [void]$colMenu.Items.Add($mi)
}
[void]$colMenu.Items.Add((New-Sep))
$miReset = New-Mi 'Reset columns' 'reset' ([string][char]0xE72C)
$miReset.Add_Click({ [US.Cols]::Build($gv, ''); Update-Headers; Show-Status 'Columns reset' })
[void]$colMenu.Items.Add($miReset)
$colMenu.Add_Opened({
    foreach ($x in $colMenu.Items) {
        if ($x -is [System.Windows.Controls.MenuItem] -and $x.IsCheckable) { $x.IsChecked = [US.Cols]::IsVisible($gv, [int]$x.Tag) }
    }
})
$btnCols.Add_Click({ $colMenu.PlacementTarget = $btnCols; $colMenu.Placement = 'Bottom'; $colMenu.IsOpen = $true })

# ---------------- list events ----------------
$list.Add_PreviewMouseLeftButtonUp({
    if ([US.Ui]::DragStarted) { return }
    if ([System.Windows.Input.Keyboard]::Modifiers -ne [System.Windows.Input.ModifierKeys]::None) { return }
    $tag = [US.Ui]::HitTag($_.OriginalSource)
    if ($tag) {
        $li = [US.Ui]::FindItem($_.OriginalSource)
        if ($li -and $li.Content) { if ($tag -eq 'pathhit') { Open-Folder $li.Content.It } else { Open-Item $li.Content.It } }
    }
})
$gridList.Add_PreviewMouseLeftButtonUp({
    if ([System.Windows.Input.Keyboard]::Modifiers -ne [System.Windows.Input.ModifierKeys]::None) { return }
    $t = [US.Ui]::FindTile($_.OriginalSource)
    if ($t -and $t.HitItem) { $script:gridHit = $t.HitItem; Open-Item $t.HitItem.It }
})
$gridList.Add_PreviewMouseRightButtonDown({
    $t = [US.Ui]::FindTile($_.OriginalSource)
    $script:gridHit = $(if ($t) { $t.HitItem } else { $null })
})
# right-click menu: work out which picture is under the mouse at the moment the menu opens
$gridList.Add_ContextMenuOpening({
    $t = [US.Ui]::FindTile($_.OriginalSource)
    if (-not $t) { $t = [US.Ui]::FindTile([System.Windows.Input.Mouse]::DirectlyOver) }
    if ($t -and $t.HitItem) { $script:gridHit = $t.HitItem }
    if (-not $script:gridHit) { $_.Handled = $true }
})
$gridList.Add_SizeChanged({ if ($script:viewMode -eq 'grid' -and (Set-GridCols)) { Update-GridNote } })
$list.Add_MouseDoubleClick({
    $li = [US.Ui]::FindItem($_.OriginalSource)
    if ($li -and $li.Content -and -not [US.Ui]::HitTag($_.OriginalSource)) { Open-Item $li.Content.It }
})
$list.Add_PreviewMouseRightButtonDown({
    $li = [US.Ui]::FindItem($_.OriginalSource)
    if ($li -and -not $li.IsSelected) { $list.SelectedItems.Clear(); $li.IsSelected = $true }
})
$list.Add_PreviewKeyDown({
    $k = $_.Key.ToString()
    $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    if ($k -eq 'Return') { $_.Handled = $true; if ($ctrl) { Show-InFolder (Get-Selected) } else { Open-Selected } }
    elseif ($k -eq 'Escape') { $_.Handled = $true; [void]$searchBox.Focus() }
    elseif ($k -eq 'C' -and $ctrl) { $_.Handled = $true; Copy-Paths }
    elseif ($k -eq 'Up' -and $list.SelectedIndex -le 0) { $_.Handled = $true; [void]$searchBox.Focus() }
})
$list.Add_PreviewTextInput({
    if ($_.Text -and -not [char]::IsControl($_.Text[0]) -and -not [char]::IsWhiteSpace($_.Text[0])) {
        $_.Handled = $true
        [void]$searchBox.Focus()
        $searchBox.Text += $_.Text
        $searchBox.CaretIndex = $searchBox.Text.Length
    }
})
$list.Add_PreviewMouseWheel({
    if (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0) {
        $_.Handled = $true
        Set-Zoom ($script:zoom + [Math]::Sign($_.Delta) * 0.1)
        Show-Status ('Zoom {0:P0}' -f $script:zoom)
    }
})

$ctx = New-Menu
foreach ($def in @(
        @('Open', 'open', [char]0xE8E5, 'Enter'),
        @('Open this path (folder)', 'folder', [char]0xE838, 'Ctrl+Enter'),
        @('Open with...', 'with', [char]0xE7AC, ''),
        'sep',
        @('Copy full path', 'path', [char]0xE8C8, 'Ctrl+C'),
        @('Copy name', 'name', [char]0xE8C8, ''),
        @('Copy folder path', 'dir', [char]0xE8C8, ''),
        'sep',
        @('Properties', 'props', [char]0xE946, ''))) {
    if ($def -is [string]) { [void]$ctx.Items.Add((New-Sep)); continue }
    $mi = New-Mi $def[0] $def[1] ([string]$def[2]) $def[3]
    if ($def[1] -eq 'open') { $mi.FontWeight = 'SemiBold' }
    $mi.Add_Click({
        param($s, $e)
        $it = Get-Selected
        if (-not $it) { return }
        switch ($s.Tag) {
            'open'   { Open-Selected }
            'folder' { Show-InFolder $it }
            'with'   { if (-not $it.IsDir) { Start-Process rundll32.exe -ArgumentList ('shell32.dll,OpenAs_RunDLL ' + $it.FullName) } }
            'path'   { Copy-Paths }
            'name'   { Copy-Text $it.Name 'Name copied' }
            'dir'    { Copy-Text $it.Folder 'Folder path copied' }
            'props'  { try { [US.Ui]::ShowProperties($it.FullName) } catch { } }
        }
    })
    [void]$ctx.Items.Add($mi)
}
$list.ContextMenu = $ctx
$ctx.Add_Opened({
    [US.Ui]::MenuOpen = $true
    # opened on a picture: move the pointer onto "Open this path (folder)", between the text and Ctrl+Enter
    if ([object]::ReferenceEquals($ctx.PlacementTarget, $gridList)) {
        [void]$w.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Input, [Action]{
            $mi = $ctx.Items | Where-Object { $_ -is [System.Windows.Controls.MenuItem] -and $_.Tag -eq 'folder' } | Select-Object -First 1
            if ($mi) { [US.Ui]::PointAt($mi, 0.62) }
        })
    }
})
$ctx.Add_Closed({ [US.Ui]::MenuOpen = $false })
$gridList.ContextMenu = $ctx      # same right-click menu for the image grid (must come after $ctx is built)

# ---------------- update index panel; "Advanced" (index file location) needs the password ----------------
function Hide-Advanced { $advSection.Visibility = 'Collapsed'; $advLbl.Text = 'Advanced' }
function Show-Lock {
    $pwdBox.Clear(); $pwdMsg.Text = ''
    $lockOverlay.Visibility = 'Visible'
    [void]$pwdBox.Focus()
}
function Try-Unlock {
    if ($pwdBox.Password -eq $AdminPassword) {
        $lockOverlay.Visibility = 'Collapsed'
        $pwdBox.Clear()
        $txtIndex.Text = $script:sharedDir
        Update-AdvInfo
        $advSection.Visibility = 'Visible'
        $advLbl.Text = 'Hide advanced'
    } else {
        $pwdMsg.Text = 'Wrong password.'
        $pwdBox.SelectAll()
    }
}
function Add-AdvRow([string]$k, [string]$v) {
    $r = $advGrid.RowDefinitions.Count
    $advGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))
    $a = New-Object System.Windows.Controls.TextBlock
    $a.Text = $k; $a.FontSize = 11.5; $a.Foreground = '#64748B'; $a.Margin = '0,0,12,5'
    $b = New-Object System.Windows.Controls.TextBlock
    $b.Text = $v; $b.FontSize = 11.5; $b.Foreground = '#0F172A'; $b.TextWrapping = 'Wrap'; $b.Margin = '0,0,0,5'
    [System.Windows.Controls.Grid]::SetRow($a, $r); [System.Windows.Controls.Grid]::SetRow($b, $r); [System.Windows.Controls.Grid]::SetColumn($b, 1)
    [void]$advGrid.Children.Add($a); [void]$advGrid.Children.Add($b)
}
function Update-AdvInfo {
    $advHint.Text = 'The common drive index is saved here, and every PC copies it automatically. Default: ' + (Get-DefaultShared)
    $advGrid.Children.Clear(); $advGrid.RowDefinitions.Clear()
    $fi = $null
    try { $fi = Get-Item -LiteralPath $script:masterPath -ErrorAction Stop } catch { }
    Add-AdvRow 'Index file' $script:masterPath
    if ($fi) {
        Add-AdvRow 'Size' ([US.Ui]::FormatSize($fi.Length))
        Add-AdvRow 'Last saved' ((Format-When $fi.LastWriteTime) + '  (' + (Format-Ago $fi.LastWriteTime) + ')')
    } else { Add-AdvRow 'Status' 'Not created yet - choose Common drive and click Start indexing.' }
    Add-AdvRow 'Copy on this PC' $(if ($script:masterLocal) { 'Not needed - the folder is on this PC' } else { $cacheCommon })
    Add-AdvRow 'This PC index' $pcIndexPath
}
function Get-LocalDrives { return (@([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed -and $_.IsReady } | ForEach-Object { $_.Name }) -join '; ') }
function Set-IdxMode([string]$m) {
    if ($script:idxMode -eq $m) { return }
    if ($script:idxMode -eq 'pc') { $cfg['pcdrive'] = $txtDrive.Text } else { $cfg['drive'] = $txtDrive.Text }
    $script:idxMode = $m
    if ($m -eq 'pc') {
        if (-not $cfg['pcdrive']) { $cfg['pcdrive'] = Get-LocalDrives }
        $txtDrive.Text = $cfg['pcdrive']
        $pcOpts.Visibility = 'Visible'; $lblDepthHint.Visibility = 'Collapsed'
        $lblDriveCap.Text = 'Drives or folders on this PC (separate several with ;)'
    } else {
        $txtDrive.Text = $cfg['drive']
        $pcOpts.Visibility = 'Collapsed'; $lblDepthHint.Visibility = 'Visible'
        $lblDriveCap.Text = 'Drive or folder to scan (separate several with ;)'
    }
    $lblProg.Text = ''
    Update-IdxState
    [void](Test-Inputs $false)
}
$rbModeNas.Add_Checked({ Set-IdxMode 'nas' })
$rbModePc.Add_Checked({ Set-IdxMode 'pc' })
function Close-Panel { $panel.Visibility = 'Collapsed'; Hide-Advanced }
$btnIdx.Add_Click({
    $helpPanel.Visibility = 'Collapsed'; $sharePanel.Visibility = 'Collapsed'
    if ($panel.Visibility -eq 'Visible') { Close-Panel } else { $panel.Visibility = 'Visible'; [void](Test-Inputs $false) }
})
$btnHelp.Add_Click({
    Close-Panel; $sharePanel.Visibility = 'Collapsed'
    if ($helpPanel.Visibility -eq 'Visible') { $helpPanel.Visibility = 'Collapsed' } else { $helpPanel.Visibility = 'Visible' }
})
$btnHelpClose.Add_Click({ $helpPanel.Visibility = 'Collapsed' })
$btnShare.Add_Click({
    Close-Panel; $helpPanel.Visibility = 'Collapsed'
    if ($sharePanel.Visibility -eq 'Visible') { $sharePanel.Visibility = 'Collapsed' } else { Build-SharePanel; $zipMsg.Text = ''; $sharePanel.Visibility = 'Visible' }
})
$btnShareClose.Add_Click({ $sharePanel.Visibility = 'Collapsed' })
$btnZip.Add_Click({ Save-Zip })
$btnResetFilters.Add_Click({ Reset-Filters })
$btnAdv.Add_Click({ if ($advSection.Visibility -eq 'Visible') { Hide-Advanced } else { Show-Lock } })
$pwdOk.Add_Click({ Try-Unlock })
$pwdCancel.Add_Click({ $lockOverlay.Visibility = 'Collapsed'; $pwdBox.Clear() })
$pwdBox.Add_KeyDown({
    if ($_.Key.ToString() -eq 'Return') { Try-Unlock }
    elseif ($_.Key.ToString() -eq 'Escape') { $lockOverlay.Visibility = 'Collapsed'; $pwdBox.Clear() }
})
$btnClose.Add_Click({ Close-Panel })
$btnBrowse.Add_Click({
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Choose the shared folder for the index (on the common drive, writable by all users)'
    if (Test-Path -LiteralPath $txtIndex.Text -PathType Container) { $dlg.SelectedPath = $txtIndex.Text }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtIndex.Text = $dlg.SelectedPath }
})
$btnShowIdx.Add_Click({
    if (Test-Path -LiteralPath $script:masterPath -PathType Leaf) { [void][US.Ui]::ShowInFolderAsync($script:masterPath) }
    elseif (Test-Path -LiteralPath $script:sharedDir -PathType Container) { [void][US.Ui]::OpenAsync($script:sharedDir, $true) }
    else { $lblIndexMsg.Text = 'The shared folder does not exist yet. It is created with the first Common drive index.' }
})
$btnUse.Add_Click({
    $p = $txtIndex.Text.Trim().Trim('"')
    if ($p -like '*.usx' -or $p -like '*.csv') { $p = Split-Path -Parent $p }
    if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Container)) {
        $lblIndexMsg.Text = 'That folder does not exist or the drive is not connected.'
        return
    }
    $cfg['shared'] = $(if ($p.TrimEnd('\') -eq (Get-DefaultShared).TrimEnd('\')) { '' } else { $p })
    $cfg['nasstamp'] = ''
    Save-Cfg
    Set-SharedPaths
    $txtIndex.Text = $script:sharedDir
    Update-AdvInfo
    $lblIndexMsg.Text = ''
    $script:nasIdx = $null; $script:nasMeta = ''; $script:nasFile = ''
    Set-Combined
    if ($script:masterLocal) {
        if (Test-Path -LiteralPath $script:masterPath -PathType Leaf) { Start-Load $script:masterPath 'nas' } else { Show-NoIndex '' }
    } else { Start-Sync }
    Show-Status 'Shared index folder changed'
})

function Start-Indexing {
    $roots = @($txtDrive.Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { if ($_ -notmatch '\\$') { $_ + '\' } else { $_ } })
    $depth = 999; $tmp = 0
    if ($txtDepth.Text.Trim() -ne '' -and [int]::TryParse($txtDepth.Text.Trim(), [ref]$tmp)) { $depth = $tmp }
    $threads = 16
    if ([int]::TryParse($txtThreads.Text.Trim(), [ref]$tmp) -and $tmp -gt 0) { $threads = [Math]::Min(64, $tmp) }
    $txtThreads.Text = [string]$threads
    $cfg['threads'] = [string]$threads
    Save-Cfg
    $meta = 'built=' + [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss', $inv) + "`nby=" + $env:COMPUTERNAME + ' (' + $env:USERNAME + ')' +
            "`nroots=" + ($roots -join ';') + "`ndepth=" + $txtDepth.Text.Trim() + "`nkind=" + $script:idxMode
    $ix = New-Object US.Indexer
    if ($script:idxMode -eq 'pc') {
        $ex = $(if ($chkDocsOnly.IsChecked) { $pcExts } else { '' })
        $ix.Start([string[]]$roots, $depth, $threads, $pcIndexPath, $null, $null, $meta, [bool]$chkSkipSys.IsChecked, $ex)
    } else {
        if (-not $cfg['shared']) { $cfg['drive'] = $txtDrive.Text; Set-SharedPaths }
        if (-not (Test-Path -LiteralPath $script:sharedDir -PathType Container)) {
            try { [void](New-Item -ItemType Directory -Path $script:sharedDir -Force -ErrorAction Stop) }
            catch { $lblProg.Text = 'I could not create the shared folder ' + $script:sharedDir + '. Ask the admin to check Advanced.'; return }
        }
        Set-Lock
        if ($script:masterLocal) { $ix.Start([string[]]$roots, $depth, $threads, $script:masterPath, $null, $null, $meta, $false, '') }
        else { $ix.Start([string[]]$roots, $depth, $threads, ($cacheCommon + '.build'), $script:masterPath, $cacheCommon, $meta, $false, '') }
    }
    $script:ixMode = $script:idxMode
    $script:indexer = $ix
    $script:sw = [System.Diagnostics.Stopwatch]::StartNew()
    $btnStart.Content = 'Stop'
    $btnStart.IsEnabled = $true
    $poll.Start()
}
$btnStart.Add_Click({
    if ($script:indexer) { $script:indexer.Cancel = $true; $lblProg.Text = 'Stopping...'; return }
    $lblProg.Text = 'Checking...'
    $w.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $ok = Test-Inputs $true
        $busy = $null; $meta = $null
        if ($ok -and $script:idxMode -eq 'nas') {
            $busy = Get-LockInfo
            $meta = [US.IndexFile]::ReadMeta($script:masterPath)      # the newest info, straight from the shared folder
        }
    } finally { $w.Cursor = $null }
    if (-not $ok) { $lblProg.Text = 'Please fix the highlighted fields.'; return }
    if ($busy) { $lblProg.Text = $busy; return }
    $lblProg.Text = ''
    if ($script:idxMode -eq 'pc') { $when = Get-MetaTime $script:pcMeta $null; $what = 'this PC' }
    else {
        if (-not $meta) { $meta = $script:nasMeta }
        $when = Get-MetaTime $meta $(if ($script:nasIdx) { $script:nasFile } else { $null })
        $what = 'the common drive'
    }
    if (-not $when) { Start-Indexing; return }
    $by = [string][US.IndexFile]::Get($meta, 'by')
    $msg = 'The index of ' + $what + ' was last updated on ' + (Format-When $when) + ' (' + (Format-Ago $when) + ')' +
           $(if ($by -and $script:idxMode -eq 'nas') { ' by ' + $by } else { '' }) + '.' + [Environment]::NewLine + [Environment]::NewLine
    if ($script:idxMode -eq 'pc') { $msg += 'Update me again only if new files on this PC are missing from the results.' }
    else { $msg += 'Updating scans the whole drive and puts extra load on the NAS. Every PC already gets my latest index automatically - update only if new files are missing from the results.' }
    Show-Confirm 'Shall I update the index?' $msg 'Update index' { Start-Indexing } ([string][char]0xE72C)
})
$dlgOk.Add_Click({ Close-Confirm $true })
$dlgCancel.Add_Click({ Close-Confirm $false })

# ---------------- window events ----------------
$w.Add_PreviewKeyDown({
    $k = $_.Key.ToString()
    $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    if ($dlgOverlay.Visibility -eq 'Visible') {
        if ($k -eq 'Escape') { $_.Handled = $true; Close-Confirm $false }
        elseif ($k -eq 'Return') { $_.Handled = $true; Close-Confirm (-not $dlgCancel.IsKeyboardFocused) }
        return
    }
    if ($k -eq 'Space' -and -not $ctrl) {
        # Space pressed twice quickly (outside a text field) jumps to the search box
        $fe = [System.Windows.Input.Keyboard]::FocusedElement
        if (-not ($fe -is [System.Windows.Controls.TextBox] -or $fe -is [System.Windows.Controls.PasswordBox])) {
            $_.Handled = $true
            $now = [DateTime]::Now
            if (($now - $script:lastSpace).TotalMilliseconds -lt 500) {
                $script:lastSpace = [DateTime]::MinValue
                [void]$searchBox.Focus()
                $searchBox.CaretIndex = $searchBox.Text.Length
            } else { $script:lastSpace = $now }
        }
    }
    elseif ($k -eq 'F3' -or ($ctrl -and ($k -eq 'F' -or $k -eq 'L'))) { $_.Handled = $true; [void]$searchBox.Focus(); $searchBox.SelectAll() }
    elseif ($ctrl -and ($k -eq 'OemPlus' -or $k -eq 'Add')) { $_.Handled = $true; Set-Zoom ($script:zoom + 0.1); Show-Status ('Zoom {0:P0}' -f $script:zoom) }
    elseif ($ctrl -and ($k -eq 'OemMinus' -or $k -eq 'Subtract')) { $_.Handled = $true; Set-Zoom ($script:zoom - 0.1); Show-Status ('Zoom {0:P0}' -f $script:zoom) }
    elseif ($ctrl -and ($k -eq 'D0' -or $k -eq 'NumPad0')) { $_.Handled = $true; Set-Zoom 1; Show-Status 'Zoom 100%' }
})
$w.Add_SourceInitialized({
    $h = (New-Object System.Windows.Interop.WindowInteropHelper $w).Handle
    $la = Get-LaunchArgs
    $cmd = if ($la) { '"' + (Get-LaunchTarget) + '" ' + $la } else { '' }
    [US.Ui]::SetWindowAppProps($h, $AppId, $cmd, $icoPath + ',0', 'Universal Search')
})
$w.Add_PreviewMouseDown({
    # a click anywhere outside the help / share panel closes it
    if ($helpPanel.Visibility -ne 'Visible' -and $sharePanel.Visibility -ne 'Visible') { return }
    $d = $_.OriginalSource -as [System.Windows.DependencyObject]
    while ($d) {
        if ($d -eq $helpPanel -or $d -eq $btnHelp -or $d -eq $sharePanel -or $d -eq $btnShare) { return }
        $d = if ($d -is [System.Windows.Media.Visual]) { [System.Windows.Media.VisualTreeHelper]::GetParent($d) } else { [System.Windows.LogicalTreeHelper]::GetParent($d) }
    }
    $helpPanel.Visibility = 'Collapsed'
    $sharePanel.Visibility = 'Collapsed'
})
$w.Add_SizeChanged({ if (-not $script:compact) { [US.Ui]::AnimMargin($topPanel, (Get-HeroTop), 1) } })
$w.Add_Closing({
    param($s, $e)
    if (-not $script:closeOk) {
        # ask first - an accidental click on X should not close the app
        $e.Cancel = $true
        if ($dlgOverlay.Visibility -eq 'Visible') { return }
        $msg = $(if ($script:indexer) { 'I am still updating the index. If you close me now, I stop and keep the previous index.' } else { 'You can open me any time from the desktop or the taskbar.' })
        Show-Confirm 'Closing me?' $msg 'Close me' { $script:closeOk = $true; $w.Close() } ([string][char]0xE7E8)
        return
    }
    if ($script:indexer) { $script:indexer.Cancel = $true }
    Remove-Lock
    Save-Cfg
})
$w.Add_Activated({ if ($script:lastSync -ne [DateTime]::MinValue -and ([DateTime]::Now - $script:lastSync).TotalMinutes -ge 10) { Start-Sync } })
$w.Add_ContentRendered({
    # come to the front (the console that started us briefly had the focus)
    $w.Topmost = $true
    [US.Ui]::BringToFront((New-Object System.Windows.Interop.WindowInteropHelper $w).Handle)
    $w.Activate() | Out-Null
    $w.Topmost = $false
    [void]$searchBox.Focus()
})
$w.Add_Loaded({
  try {
    [US.Ui]::AnimMargin($topPanel, (Get-HeroTop), 1)
    [void]$searchBox.Focus()
    $z = 1.0
    if ([double]::TryParse([string]$cfg['zoom'], [Globalization.NumberStyles]::Float, $inv, [ref]$z)) { Set-Zoom $z }
    Restore-View
    Update-Greeting
    Update-Shortcut
    Set-SharedPaths
    $chkSkipSys.IsChecked = ($cfg['pcskip'] -ne '0')
    $chkDocsOnly.IsChecked = ($cfg['pcdocs'] -ne '0')
    Update-IdxState
    Set-InfoText 'Loading index...' 'Folder depth -' 'Last index updated -'
    if (Test-Path -LiteralPath $pcIndexPath -PathType Leaf) { Start-Load $pcIndexPath 'pc' }
    if ($script:masterLocal) {
        if (Test-Path -LiteralPath $script:masterPath -PathType Leaf) { Start-Load $script:masterPath 'nas' } else { Show-NoIndex '' }
    } elseif (Test-Path -LiteralPath $cacheCommon -PathType Leaf) {
        # search at once with the copy on this PC, then check the shared folder for a newer one
        $script:syncAfterLoad = $true
        Start-Load $cacheCommon 'nas'
    } else { Start-Sync }
    $syncTimer.Start()
    $clockTimer.Start()
  } catch {
    # never close silently: show what went wrong and keep the window open
    $lblStatus.Text = 'Start-up problem: ' + $_.Exception.Message
    try { Set-Content -LiteralPath (Join-Path $env:TEMP 'UniversalSearch-error.txt') -Value ($_ | Out-String) } catch { }
  }
})

[void]$w.ShowDialog()

} catch {
    $msg = (($Error | ForEach-Object { $_.ToString() } | Select-Object -First 12) -join ([Environment]::NewLine + [Environment]::NewLine))
    try { Set-Content -LiteralPath (Join-Path $env:TEMP 'UniversalSearch-error.txt') -Value $msg } catch { }
    [System.Windows.MessageBox]::Show($msg, 'Universal Search - Error') | Out-Null
}

} *> $null
