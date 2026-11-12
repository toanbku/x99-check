<#
  X99 DISK CHECK - kiem tra o cung (HDD / SSD / NVMe) truoc khi mua do cu. Chay rieng voi check.ps1.

  Cach chay de nhat: bam dup disk.bat (tu xin quyen Admin).
  Hoac:  powershell -ExecutionPolicy Bypass -File disk-check.ps1 [-Quick] [-DiskNumber 1] [-FullRead] [-NoWrite]

  Script lam gi (moi o):
    1. Ten, serial, loai (HDD/SSD/NVMe), dung luong, Windows danh gia o ra sao
    2. SMART: gio da chay, so lan bat, sector hong / cho xu ly, % tuoi tho SSD, nhiet do
    3. Lich su loi o dia trong log Windows (90 ngay)
    4. Doc thu be mat o (CHI DOC): toc do dau/giua/cuoi o + doc rai rac khap o tim cho loi / cho doc cham
       (-FullRead: doc het ca o, lau: HDD 1TB mat ~2 tieng)
    5. Ghi 1 file tam (mac dinh 2GB) vao phan trong, doc lai so tung byte, xong file tu xoa
  Khong dung vao du lieu co san tren o.

  Ma thoat: 0 = khong thay loi, 1 = co LOI hoac CHU Y, 2 = ban than script bi loi.
#>
[CmdletBinding()]
param(
    [int]$DiskNumber = -1,
    [int]$WriteTestGB = 2,
    [int]$ReadSamples = 400,
    [switch]$FullRead,
    [switch]$NoWrite,
    [switch]$Quick,
    [switch]$InjectErrors   # chi de tu kiem tra script: co tinh lam sai 1 doan trong file test
)

$ErrorActionPreference = 'Stop'

trap {
    Write-Host ''
    Write-Host ('SCRIPT BI LOI: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    try { Stop-Transcript | Out-Null } catch {}
    exit 2
}

if ($Quick) { $ReadSamples = 60; $WriteTestGB = 1 }

# C# 5 (Add-Type cua Windows PowerShell 5.1). Doc/ghi khong qua cache cua Windows (NO_BUFFERING)
# de do dung toc do that va doc dung du lieu nam tren o.
$cs = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public static class X99Disk
{
    const uint GENERIC_READ = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint SHARE_RW = 3;
    const uint OPEN_EXISTING = 3;
    const uint CREATE_ALWAYS = 2;
    const uint NO_BUFFERING = 0x20000000;
    const uint WRITE_THROUGH = 0x80000000;
    const uint DELETE_ON_CLOSE = 0x04000000;
    const double SlowMs = 500;
    const ulong K = 0x9E3779B97F4A7C15UL;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(SafeFileHandle h, IntPtr buf, uint n, out uint done, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(SafeFileHandle h, IntPtr buf, uint n, out uint done, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFilePointerEx(SafeFileHandle h, long dist, out long pos, uint method);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr VirtualAlloc(IntPtr addr, UIntPtr size, uint type, uint protect);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool VirtualFree(IntPtr addr, UIntPtr size, uint type);

    public static volatile bool Done;
    public static volatile bool Inject;
    public static volatile int Percent;
    public static volatile string Phase = "";
    public static long IoErrors;
    public static long SlowReads;
    public static long VerifyErrors;
    public static double MaxMs;
    public static double SeqStart;
    public static double SeqMid;
    public static double SeqEnd;
    public static double RandAvgMs;
    public static double WriteMBps;
    public static double ReadMBps;
    public static long BytesTested;
    public static string Fatal = "";
    static readonly List<string> Log = new List<string>();

    public static string[] GetLog() { lock (Log) return Log.ToArray(); }
    static void AddLog(string s) { lock (Log) { if (Log.Count < 15) Log.Add(s); } }

    static void Reset()
    {
        Done = false; Percent = 0; Phase = ""; IoErrors = 0; SlowReads = 0; VerifyErrors = 0; MaxMs = 0;
        SeqStart = 0; SeqMid = 0; SeqEnd = 0; RandAvgMs = 0; WriteMBps = 0; ReadMBps = 0; BytesTested = 0; Fatal = "";
        lock (Log) Log.Clear();
    }

    static IntPtr Alloc(int n) { return VirtualAlloc(IntPtr.Zero, new UIntPtr((uint)n), 0x3000, 4); }
    static void Free(IntPtr p) { if (p != IntPtr.Zero) VirtualFree(p, UIntPtr.Zero, 0x8000); }
    static double Mbps(long bytes, Stopwatch sw) { double s = sw.Elapsed.TotalSeconds; return s > 0 ? bytes / 1048576.0 / s : 0; }

    // ---------------- doc be mat o (chi doc) ----------------
    public static void StartScan(int disk, long size, int samples, bool full)
    {
        Reset();
        var t = new Thread(() => Scan(disk, size, samples, full));
        t.IsBackground = true;
        t.Start();
    }

    static bool ReadAt(SafeFileHandle h, IntPtr buf, long off, int len, out double ms)
    {
        var sw = Stopwatch.StartNew();
        long pos;
        uint got = 0;
        bool ok = SetFilePointerEx(h, off, out pos, 0) && ReadFile(h, buf, (uint)len, out got, IntPtr.Zero) && got == (uint)len;
        int err = ok ? 0 : Marshal.GetLastWin32Error();
        ms = sw.Elapsed.TotalMilliseconds;
        if (!ok)
        {
            IoErrors++;
            AddLog(string.Format("DOC LOI o vi tri {0:N0} MB (ma loi Windows {1})", off >> 20, err));
        }
        else
        {
            BytesTested += len;
            if (ms > SlowMs)
            {
                SlowReads++;
                AddLog(string.Format("Doc cham {0:N0} ms o vi tri {1:N0} MB", ms, off >> 20));
            }
        }
        if (ms > MaxMs) MaxMs = ms;
        return ok;
    }

    static double SeqRead(SafeFileHandle h, IntPtr buf, long start, int chunk, long count)
    {
        var sw = Stopwatch.StartNew();
        double ms;
        long okBytes = 0;
        for (long i = 0; i < count; i++)
            if (ReadAt(h, buf, start + i * chunk, chunk, out ms)) okBytes += chunk;
        return Mbps(okBytes, sw);
    }

    static void Scan(int disk, long size, int samples, bool full)
    {
        const int CH = 1 << 20;
        IntPtr buf = IntPtr.Zero;
        try
        {
            using (var h = CreateFileW(@"\\.\PhysicalDrive" + disk, GENERIC_READ, SHARE_RW, IntPtr.Zero, OPEN_EXISTING, NO_BUFFERING, IntPtr.Zero))
            {
                if (h.IsInvalid) { Fatal = "Khong mo duoc o de doc (can quyen Admin), ma loi " + Marshal.GetLastWin32Error(); return; }
                buf = Alloc(CH);
                long chunks = size / CH;
                if (chunks < 1) { Fatal = "O qua nho"; return; }
                if (full)
                {
                    Phase = "full";
                    var sw = Stopwatch.StartNew();
                    double ms;
                    long okBytes = 0;
                    for (long i = 0; i < chunks; i++)
                    {
                        if (ReadAt(h, buf, i * CH, CH, out ms)) okBytes += CH;
                        Percent = (int)(i * 100 / chunks);
                    }
                    SeqStart = Mbps(okBytes, sw);
                    SeqMid = SeqStart;
                    SeqEnd = SeqStart;
                }
                else
                {
                    long seq = Math.Min(256, chunks);
                    Phase = "seq";
                    SeqStart = SeqRead(h, buf, 0, CH, seq);
                    Percent = 10;
                    long mid = chunks / 2;
                    SeqMid = SeqRead(h, buf, mid * CH, CH, Math.Min(seq, chunks - mid));
                    Percent = 20;
                    SeqEnd = SeqRead(h, buf, (chunks - seq) * CH, CH, seq);
                    Percent = 30;
                    Phase = "random";
                    var rnd = new Random(12345);
                    double total = 0;
                    double ms;
                    long seg = samples > 0 ? chunks / samples : 0;
                    for (int i = 0; i < samples; i++)
                    {
                        // chia o thanh 'samples' doan deu nhau, moi doan doc 1 cho ngau nhien
                        long c = (long)i * seg + (seg > 0 ? (long)(rnd.NextDouble() * seg) : 0);
                        if (c > chunks - 1) c = chunks - 1;
                        ReadAt(h, buf, c * CH, CH, out ms);
                        total += ms;
                        Percent = 30 + (int)(70L * (i + 1) / samples);
                    }
                    RandAvgMs = samples > 0 ? total / samples : 0;
                }
            }
        }
        catch (Exception e) { Fatal = e.Message; }
        finally { Free(buf); Percent = 100; Done = true; }
    }

    // ---------------- ghi file tam roi doc lai ----------------
    public static void StartWrite(string path, long bytes)
    {
        Reset();
        var t = new Thread(() => WriteTest(path, bytes));
        t.IsBackground = true;
        t.Start();
    }

    static void Pattern(long[] a, long chunk)
    {
        ulong basev = (ulong)chunk * (ulong)a.Length;
        for (int j = 0; j < a.Length; j++) a[j] = (long)(((basev + (ulong)j) * K) ^ 0x5A5A5A5A5A5A5A5AUL);
    }

    static void WriteTest(string path, long bytes)
    {
        const int CH = 8 << 20;
        long chunks = Math.Max(1, bytes / CH);
        IntPtr buf = IntPtr.Zero;
        var a = new long[CH / 8];
        var r = new long[CH / 8];
        try
        {
            buf = Alloc(CH);
            // DELETE_ON_CLOSE: file tu xoa khi dong, ke ca khi script bi tat ngang
            using (var h = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, IntPtr.Zero, CREATE_ALWAYS,
                NO_BUFFERING | WRITE_THROUGH | DELETE_ON_CLOSE, IntPtr.Zero))
            {
                if (h.IsInvalid) { Fatal = "Khong tao duoc file test " + path + ", ma loi " + Marshal.GetLastWin32Error(); return; }
                Phase = "write";
                var sw = Stopwatch.StartNew();
                long written = 0;
                uint n;
                long pos;
                for (long i = 0; i < chunks; i++)
                {
                    Pattern(a, i);
                    Marshal.Copy(a, 0, buf, a.Length);
                    if (!WriteFile(h, buf, CH, out n, IntPtr.Zero) || n != CH)
                    {
                        IoErrors++;
                        AddLog(string.Format("GHI LOI o doan {0:N0} MB (ma loi Windows {1})", i * 8, Marshal.GetLastWin32Error()));
                        break;
                    }
                    written++;
                    Percent = (int)(50 * (i + 1) / chunks);
                }
                WriteMBps = Mbps(written * CH, sw);
                if (Inject && written > 3)
                {
                    Pattern(a, 3);
                    a[1000] ^= 0xFF;
                    Marshal.Copy(a, 0, buf, a.Length);
                    SetFilePointerEx(h, 3L * CH, out pos, 0);
                    WriteFile(h, buf, CH, out n, IntPtr.Zero);
                }
                Phase = "verify";
                SetFilePointerEx(h, 0, out pos, 0);
                sw.Restart();
                long read = 0;
                for (long i = 0; i < written; i++)
                {
                    if (!ReadFile(h, buf, CH, out n, IntPtr.Zero) || n != CH)
                    {
                        IoErrors++;
                        AddLog(string.Format("DOC LAI LOI o doan {0:N0} MB (ma loi Windows {1})", i * 8, Marshal.GetLastWin32Error()));
                        break;
                    }
                    read++;
                    Marshal.Copy(buf, r, 0, r.Length);
                    Pattern(a, i);
                    int bad = 0;
                    for (int j = 0; j < a.Length; j += 512)          // so tung khoi 4KB
                        for (int k = j; k < j + 512; k++)
                            if (a[k] != r[k]) { bad++; break; }
                    if (bad > 0)
                    {
                        VerifyErrors += bad;
                        AddLog(string.Format("SAI DU LIEU: {0} khoi 4KB o doan {1:N0} MB", bad, i * 8));
                    }
                    Percent = 50 + (int)(50 * (i + 1) / written);
                }
                ReadMBps = Mbps(read * CH, sw);
                BytesTested = written * CH;
            }
        }
        catch (Exception e) { Fatal = e.Message; }
        finally { Free(buf); Percent = 100; Done = true; }
    }
}
'@

# ---------------------------------------------------------------------------
$script:Issues = New-Object 'System.Collections.Generic.List[string]'
$script:Warns = New-Object 'System.Collections.Generic.List[string]'
$script:Prefix = ''

function Write-Section([string]$Title) { Write-Host ''; Write-Host ('== ' + $Title + ' ==') -ForegroundColor Cyan }
function Write-Ok([string]$Msg) { Write-Host ('  [OK]    ' + $Msg) -ForegroundColor Green }
function Write-Bad([string]$Msg) { Write-Host ('  [LOI]   ' + $Msg) -ForegroundColor Red; $script:Issues.Add($script:Prefix + $Msg) }
function Write-Warn([string]$Msg) { Write-Host ('  [CHU Y] ' + $Msg) -ForegroundColor Yellow; $script:Warns.Add($script:Prefix + $Msg) }
function Write-Info([string]$Msg) { Write-Host ('          ' + $Msg) }

function Find-WmiByPnp([string]$Class, [string]$Pnp) {
    if (-not $Pnp) { return $null }
    try { $all = @(Get-CimInstance -Namespace root/wmi -ClassName $Class -ErrorAction Stop) } catch { return $null }
    foreach ($x in $all) {
        if (('' + $x.InstanceName).StartsWith($Pnp, [StringComparison]::OrdinalIgnoreCase)) { return $x }
    }
    return $null
}

# Doc bang SMART tho (o SATA): moi thuoc tinh 12 byte, bat dau tu byte thu 2
function Get-SmartAttrs([string]$Pnp) {
    $d = Find-WmiByPnp 'MSStorageDriver_FailurePredictData' $Pnp
    if (-not $d -or -not $d.VendorSpecific) { return $null }
    $b = [byte[]]$d.VendorSpecific
    $attrs = @{}
    for ($i = 0; $i -lt 30; $i++) {
        $o = 2 + $i * 12
        if ($o + 11 -ge $b.Length) { break }
        $id = [int]$b[$o]
        if ($id -eq 0) { continue }
        $raw = [double]0
        for ($k = 5; $k -ge 0; $k--) { $raw = $raw * 256 + $b[$o + 5 + $k] }
        $attrs[$id] = [pscustomobject]@{ Cur = [int]$b[$o + 3]; Worst = [int]$b[$o + 4]; Raw = $raw }
    }
    return $attrs
}

function Get-Raw($attrs, [int]$id) { if ($attrs -and $attrs.ContainsKey($id)) { return $attrs[$id].Raw } return $null }

function Wait-Job2([string]$Label) {
    $last = -1
    $lastPhase = ''
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $names = @{ 'seq' = 'doc tuan tu'; 'random' = 'doc rai rac'; 'full' = 'doc het o'; 'write' = 'ghi'; 'verify' = 'doc lai + so' }
    while (-not [X99Disk]::Done) {
        Start-Sleep -Milliseconds 500
        $p = [X99Disk]::Percent
        $ph = [X99Disk]::Phase
        if (($ph -ne $lastPhase) -or ($p -ge $last + 10) -or ($sw.Elapsed.TotalSeconds -ge 30)) {
            if ($ph) { Write-Info ('{0} {1,-14} {2,3}%   loi: {3}' -f $Label, $names[$ph], $p, [X99Disk]::IoErrors) }
            $last = $p
            $lastPhase = $ph
            $sw.Restart()
        }
    }
}

# ---------------------------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$desk = [Environment]::GetFolderPath('Desktop')
if (-not $desk -or -not (Test-Path $desk)) { $desk = $env:TEMP }
$report = Join-Path $desk ("x99-disk-report-$stamp.txt")
try { Start-Transcript -Path $report -Force | Out-Null } catch { $report = $null }

Write-Host ''
Write-Host '=============== X99 DISK CHECK ===============' -ForegroundColor Cyan
Write-Host 'Chi doc o + ghi 1 file tam vao phan trong (tu xoa). Khong dung vao du lieu co san.'

if (-not [Environment]::Is64BitProcess) {
    Write-Host 'Phai chay bang PowerShell 64-bit (dung disk.bat).' -ForegroundColor Red
    exit 2
}
$isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Warn 'Khong chay quyen Admin: khong doc duoc SMART va be mat o. Hay chay bang disk.bat.' }

if (-not ('X99Disk' -as [type])) { Add-Type -TypeDefinition $cs -Language CSharp }

# --- Danh sach o ---------------------------------------------------------------
Write-Section 'Danh sach o'
$pds = @(Get-PhysicalDisk | Sort-Object { [int]$_.DeviceId })
if ($DiskNumber -ge 0) { $pds = @($pds | Where-Object { [int]$_.DeviceId -eq $DiskNumber }) }
if ($pds.Count -eq 0) { Write-Bad 'Khong thay o nao'; }
$dd = @{}
foreach ($x in @(Get-CimInstance Win32_DiskDrive)) { $dd[[int]$x.Index] = $x }

function Get-Kind($pd) {
    if (('' + $pd.BusType) -eq 'NVMe') { return 'NVMe' }
    if (('' + $pd.MediaType) -eq 'SSD') { return 'SSD' }
    if (('' + $pd.MediaType) -eq 'HDD') { return 'HDD' }
    return '?'
}

$pds | ForEach-Object {
    $n = [int]$_.DeviceId
    $isBoot = $false
    try { $gd = Get-Disk -Number $n -ErrorAction Stop; $isBoot = [bool]($gd.IsBoot -or $gd.IsSystem) } catch {}
    [pscustomobject]@{
        So        = $n
        Ten       = ('' + $_.FriendlyName).Trim()
        Loai      = '{0} ({1})' -f (Get-Kind $_), $_.BusType
        GB        = [math]::Round([double]$_.Size / 1GB)
        Serial    = ('' + $_.SerialNumber).Trim()
        Firmware  = ('' + $_.FirmwareVersion).Trim()
        WindowsBao = '' + $_.HealthStatus
        ChayWin   = $(if ($isBoot) { 'co' } else { '' })
    }
} | Format-Table -AutoSize | Out-String -Width 220 | Write-Host

# --- Lich su loi (doc 1 lan) --------------------------------------------------
$since = (Get-Date).AddDays(-90)
$evByDisk = @{}
try {
    foreach ($e in @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'disk'; Id = 7, 11, 51, 153; StartTime = $since } -ErrorAction Stop)) {
        if (('' + $e.Message) -match 'Harddisk(\d+)') {
            $k = [int]$Matches[1]
            if (-not $evByDisk.ContainsKey($k)) { $evByDisk[$k] = @{ 7 = 0; 11 = 0; 51 = 0; 153 = 0 } }
            $evByDisk[$k][[int]$e.Id]++
        }
    }
}
catch {}
$resetEvents = 0
foreach ($prov in @('storahci', 'stornvme', 'iaStorA', 'iaStorAC', 'iaStorAVC', 'iaStorV')) {
    try { $resetEvents += @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = $prov; Id = 129; StartTime = $since } -ErrorAction Stop).Count } catch {}
}
$ntfsEvents = 0
try { $ntfsEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Ntfs', 'Microsoft-Windows-Ntfs'; Id = 55; StartTime = $since } -ErrorAction Stop).Count } catch {}

# --- Tung o -------------------------------------------------------------------
foreach ($pd in $pds) {
    $n = [int]$pd.DeviceId
    $kind = Get-Kind $pd
    $name = ('' + $pd.FriendlyName).Trim()
    $sizeGB = [math]::Round([double]$pd.Size / 1GB)
    $script:Prefix = ('O {0} ({1}): ' -f $n, $name)
    Write-Section ('O so {0}: {1} | {2} {3} | {4}GB' -f $n, $name, $kind, $pd.BusType, $sizeGB)

    # 1. Windows danh gia
    $hs = '' + $pd.HealthStatus
    if ($hs -eq 'Healthy') { Write-Ok 'Windows danh gia: Healthy' }
    elseif ($hs -eq 'Unhealthy') { Write-Bad 'Windows danh gia: UNHEALTHY (o sap hong)' }
    else { Write-Warn ('Windows danh gia: ' + $hs) }
    $ops = (@($pd.OperationalStatus) | ForEach-Object { '' + $_ }) -join ','
    if ($ops -and $ops -ne 'OK') { Write-Warn ('Trang thai hoat dong: ' + $ops) }

    # 2. SMART
    $src = $dd[$n]
    $pnp = ''
    if ($src) { $pnp = '' + $src.PNPDeviceID }
    $smart = Get-SmartAttrs $pnp
    $pf = Find-WmiByPnp 'MSStorageDriver_FailurePredictStatus' $pnp
    $rel = $null
    try { $rel = $pd | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}

    if (-not $smart -and -not $rel) {
        Write-Info 'Khong doc duoc SMART (o cam qua USB/RAID, hoac thieu quyen Admin). Dung CrystalDiskInfo de xem.'
    }
    if ($pf -and $pf.PredictFailure) { Write-Bad 'SMART BAO O SAP HONG (Predict Failure)' }

    $poh = $null
    if ($rel -and $rel.PowerOnHours) { $poh = [double]$rel.PowerOnHours }
    elseif ((Get-Raw $smart 9) -ne $null) { $poh = (Get-Raw $smart 9) % 4294967296 }
    if ($poh -ne $null) {
        $msg = 'Da chay {0:N0} gio (~{1:N1} nam bat lien tuc)' -f $poh, ($poh / 8760)
        if ($kind -eq 'HDD' -and $poh -gt 35000) { Write-Warn ($msg + ' -> HDD da chay nhieu') } else { Write-Info $msg }
    }
    $cyc = Get-Raw $smart 12
    if ($cyc -eq $null -and $rel -and $rel.StartStopCycleCount) { $cyc = [double]$rel.StartStopCycleCount }
    if ($cyc -ne $null) { Write-Info ('So lan bat may: {0:N0}' -f $cyc) }

    $temp = $null
    if ($rel -and $rel.Temperature) { $temp = [int]$rel.Temperature }
    elseif ((Get-Raw $smart 194) -ne $null) { $temp = [int]((Get-Raw $smart 194) % 256) }
    elseif ((Get-Raw $smart 190) -ne $null) { $temp = [int]((Get-Raw $smart 190) % 256) }
    if ($temp) {
        if ($kind -eq 'HDD') { $hot = 55 } else { $hot = 70 }
        if ($temp -gt $hot) { Write-Warn ('Nhiet do {0}C (nong)' -f $temp) } else { Write-Info ('Nhiet do {0}C' -f $temp) }
    }

    # tuoi tho SSD
    $life = $null
    # NVMe: Windows doc dung "% da dung". SSD SATA: Wear thuong = 0 du khong ho tro, nen chi tin khi > 0
    if ($rel -and $rel.Wear -ne $null -and (($kind -eq 'NVMe') -or ($kind -eq 'SSD' -and [int]$rel.Wear -gt 0))) { $life = 100 - [int]$rel.Wear }
    foreach ($id in 177, 231, 233, 169) {
        if ($life -eq $null -and $smart -and $smart.ContainsKey($id) -and ($kind -ne 'HDD')) { $life = [int]$smart[$id].Cur }
    }
    if ($life -ne $null -and $kind -ne 'HDD') {
        if ($life -gt 100) { $life = 100 }
        if ($life -lt 10) { Write-Bad ('SSD con {0}% tuoi tho -> sap het' -f $life) }
        elseif ($life -lt 30) { Write-Warn ('SSD con {0}% tuoi tho' -f $life) }
        else { Write-Ok ('SSD con {0}% tuoi tho' -f $life) }
    }

    if ($smart) {
        $realloc = Get-Raw $smart 5
        $pending = Get-Raw $smart 197
        $offunc = Get-Raw $smart 198
        $repunc = Get-Raw $smart 187
        $crc = Get-Raw $smart 199
        if ($pending -gt 0) { Write-Bad ('Co {0:N0} sector dang cho xu ly (Current Pending) -> be mat dang hong' -f $pending) }
        if ($offunc -gt 0) { Write-Bad ('Co {0:N0} sector khong doc duoc (Offline Uncorrectable)' -f $offunc) }
        if ($realloc -gt 0) {
            if ($realloc -ge 100) { Write-Bad ('Da thay the {0:N0} sector hong (Reallocated) -> nhieu' -f $realloc) }
            else { Write-Warn ('Da thay the {0:N0} sector hong (Reallocated)' -f $realloc) }
        }
        if ($repunc -gt 0) { Write-Warn ('Tung co {0:N0} loi khong sua duoc (Reported Uncorrectable)' -f $repunc) }
        if ($crc -gt 0) { Write-Warn ('Co {0:N0} loi truyen du lieu (UDMA CRC) -> thuong do day SATA, khong han do o' -f $crc) }
        if (-not ($pending -gt 0) -and -not ($offunc -gt 0) -and -not ($realloc -gt 0) -and -not ($repunc -gt 0)) {
            Write-Ok 'SMART: khong co sector hong / cho xu ly'
        }
    }
    if ($rel) {
        if ($rel.ReadErrorsUncorrected -gt 0) { Write-Warn ('Windows ghi nhan {0} loi doc khong sua duoc' -f $rel.ReadErrorsUncorrected) }
        if ($rel.WriteErrorsUncorrected -gt 0) { Write-Warn ('Windows ghi nhan {0} loi ghi khong sua duoc' -f $rel.WriteErrorsUncorrected) }
    }

    # 3. Lich su loi
    $ev = $evByDisk[$n]
    if ($ev) {
        if ($ev[7] -gt 0) { Write-Bad ('Log Windows: {0} lan bao bad block trong 90 ngay' -f $ev[7]) }
        if ($ev[153] -gt 0) { Write-Warn ('Log Windows: {0} lan phai doc/ghi lai (IO retried) trong 90 ngay' -f $ev[153]) }
        if ($ev[11] -gt 0) { Write-Warn ('Log Windows: {0} loi bo dieu khien (controller error)' -f $ev[11]) }
        if ($ev[51] -gt 0) { Write-Warn ('Log Windows: {0} loi khi ghi trang (paging error)' -f $ev[51]) }
    }
    else { Write-Ok 'Log Windows: khong co loi o dia trong 90 ngay' }

    # 4. Doc be mat
    if ($isAdmin) {
        if ($FullRead) { Write-Info ('Doc het {0}GB (chi doc). HDD ~100-200MB/s -> mat khoang {1:N0} phut.' -f $sizeGB, ($sizeGB * 1024 / 150 / 60)) }
        else { Write-Info ('Doc thu (chi doc): 256MB o dau/giua/cuoi + {0} cho rai khap o.' -f $ReadSamples) }
        [X99Disk]::StartScan($n, [long]$pd.Size, $ReadSamples, [bool]$FullRead)
        Wait-Job2 '  doc'
        if ([X99Disk]::Fatal) { Write-Warn ('Khong doc thu duoc: ' + [X99Disk]::Fatal) }
        else {
            if ($FullRead) { Write-Info ('Toc do doc trung binh: {0:N0} MB/s' -f [X99Disk]::SeqStart) }
            else {
                Write-Info ('Toc do doc tuan tu: dau o {0:N0} MB/s | giua {1:N0} | cuoi {2:N0}' -f [X99Disk]::SeqStart, [X99Disk]::SeqMid, [X99Disk]::SeqEnd)
                Write-Info ('Doc rai rac: trung binh {0:N1} ms, cham nhat {1:N0} ms' -f [X99Disk]::RandAvgMs, [X99Disk]::MaxMs)
            }
            foreach ($l in [X99Disk]::GetLog()) { Write-Info $l }
            if ([X99Disk]::IoErrors -gt 0) { Write-Bad ('DOC LOI {0} cho (bad sector) -> o hong' -f [X99Disk]::IoErrors) }
            elseif ([X99Disk]::SlowReads -ge 5) { Write-Bad ('{0} cho doc rat cham (>500ms) -> be mat yeu, sap co bad sector' -f [X99Disk]::SlowReads) }
            elseif ([X99Disk]::SlowReads -gt 0) { Write-Warn ('{0} cho doc cham (>500ms)' -f [X99Disk]::SlowReads) }
            else { Write-Ok ('Doc thu {0:N0}MB: khong loi, khong cho nao cham' -f ([X99Disk]::BytesTested / 1MB)) }
            $minRead = [math]::Min([X99Disk]::SeqStart, [X99Disk]::SeqEnd)
            $slowLimit = @{ 'HDD' = 50; 'SSD' = 200; 'NVMe' = 500 }[$kind]
            if ($slowLimit -and ('' + $pd.BusType) -ne 'USB' -and $minRead -lt $slowLimit) {
                Write-Warn ('Doc cham bat thuong cho {0}: {1:N0} MB/s (binh thuong > {2})' -f $kind, $minRead, $slowLimit)
            }
        }
    }

    # 5. Ghi + doc lai file tam
    if ($NoWrite) { Write-Info 'Bo qua test ghi (-NoWrite).' }
    else {
        $needGB = $WriteTestGB + 1
        $vols = @(Get-Partition -DiskNumber $n -ErrorAction SilentlyContinue |
            Where-Object { ('' + $_.DriveLetter) -match '^[A-Za-z]$' } |
            ForEach-Object { Get-Volume -DriveLetter $_.DriveLetter -ErrorAction SilentlyContinue } |
            Where-Object { @('NTFS', 'ReFS', 'exFAT', 'FAT32') -contains ('' + $_.FileSystem) } |
            Sort-Object SizeRemaining -Descending)
        foreach ($v in $vols) {
            Write-Info ('Phan vung {0}: {1} | {2:N0}GB, trong {3:N0}GB | {4}' -f $v.DriveLetter, $v.FileSystem, ($v.Size / 1GB), ($v.SizeRemaining / 1GB), $v.HealthStatus)
            if (('' + $v.HealthStatus) -ne 'Healthy' -and ('' + $v.HealthStatus)) { Write-Warn ('Phan vung {0}: {1}' -f $v.DriveLetter, $v.HealthStatus) }
        }
        $target = $vols | Where-Object { $_.SizeRemaining -ge $needGB * 1GB } | Select-Object -First 1
        if (-not $target) {
            if ($vols.Count -eq 0) { Write-Info 'O chua co phan vung co ten (C:, D:...) -> bo qua test ghi.' }
            else { Write-Info ('Khong phan vung nao trong >= {0}GB -> bo qua test ghi.' -f $needGB) }
        }
        else {
            $path = '{0}:\x99-disktest.tmp' -f $target.DriveLetter
            Write-Info ('Ghi {0}GB vao {1} roi doc lai so tung byte (file tu xoa).' -f $WriteTestGB, $path)
            [X99Disk]::Inject = [bool]$InjectErrors
            [X99Disk]::StartWrite($path, [long]$WriteTestGB * 1GB)
            Wait-Job2 '  ghi'
            if ([X99Disk]::Fatal) { Write-Warn ('Khong test ghi duoc: ' + [X99Disk]::Fatal) }
            else {
                Write-Info ('Toc do ghi {0:N0} MB/s | doc lai {1:N0} MB/s' -f [X99Disk]::WriteMBps, [X99Disk]::ReadMBps)
                foreach ($l in [X99Disk]::GetLog()) { Write-Info $l }
                if ([X99Disk]::VerifyErrors -gt 0) { Write-Bad ('SAI DU LIEU: {0} khoi 4KB doc ra khac luc ghi -> o (hoac RAM/day cap) loi' -f [X99Disk]::VerifyErrors) }
                elseif ([X99Disk]::IoErrors -gt 0) { Write-Bad ('Loi khi ghi/doc file test ({0} lan)' -f [X99Disk]::IoErrors) }
                else { Write-Ok ('Ghi roi doc lai {0}GB: dung tung byte' -f $WriteTestGB) }
                $wLimit = @{ 'HDD' = 40; 'SSD' = 100; 'NVMe' = 300 }[$kind]
                if ($wLimit -and ('' + $pd.BusType) -ne 'USB' -and [X99Disk]::WriteMBps -lt $wLimit) {
                    Write-Warn ('Ghi cham bat thuong cho {0}: {1:N0} MB/s (binh thuong > {2})' -f $kind, [X99Disk]::WriteMBps, $wLimit)
                }
            }
            if (Test-Path $path) { try { Remove-Item $path -Force } catch {} }
        }
    }
}
$script:Prefix = ''

if ($resetEvents -gt 0 -or $ntfsEvents -gt 0) {
    Write-Section 'Log Windows chung (90 ngay)'
    if ($resetEvents -gt 0) { Write-Warn ('Bo dieu khien o dia bi reset {0} lan (event 129) -> o/day cap/driver co van de' -f $resetEvents) }
    if ($ntfsEvents -gt 0) { Write-Warn ('He thong file bi loi {0} lan (Ntfs 55)' -f $ntfsEvents) }
}

# --- Tong ket -----------------------------------------------------------------
Write-Section 'TONG KET'
if ($script:Issues.Count -eq 0 -and $script:Warns.Count -eq 0) { Write-Host '  KHONG THAY LOI.' -ForegroundColor Green }
foreach ($m in $script:Issues) { Write-Host ('  [LOI]   ' + $m) -ForegroundColor Red }
foreach ($m in $script:Warns) { Write-Host ('  [CHU Y] ' + $m) -ForegroundColor Yellow }
Write-Host ''
Write-Host '  Muon xem them: CrystalDiskInfo (crystalmark.info) hien day du SMART.'
if ($report) { Write-Host ('  Bao cao da luu: ' + $report) }
try { Stop-Transcript | Out-Null } catch {}
if ($script:Issues.Count -gt 0 -or $script:Warns.Count -gt 0) { exit 1 }
exit 0
