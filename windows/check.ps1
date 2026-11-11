<#
  X99 DUAL CHECK - kiem tra bo main X99 dual + 2 CPU Xeon + RAM ECC REG truoc khi mua do cu.

  Cach chay de nhat: bam dup run.bat (tu xin quyen Admin).
  Hoac:  powershell -ExecutionPolicy Bypass -File check.ps1 [-Quick] [-StressMinutes 10] [-MemPasses 2]

  Script lam gi:
    1. Doc thong tin Windows, main, BIOS, CPU, tung thanh RAM (hang, ma, loai RDIMM/LRDIMM, bus)
    2. So voi cau hinh nguoi ban noi (mac dinh: 2x E5-2686 v4, 72 luong, 4x32GB = 128GB, Samsung)
    3. Xem lich su loi phan cung trong log Windows (90 ngay)
    4. Test RAM: ghi/doc lai 6 mau len ~85% RAM dang trong
    5. Chay nang tat ca luong CPU, kiem tra tinh dung + xung co bi tut (qua nhiet / main-nguon yeu)
    6. Kiem tra Windows co ghi loi phan cung (WHEA, ECC) trong luc test khong

  Ma thoat: 0 = khong thay loi, 1 = co LOI hoac CHU Y, 2 = ban than script bi loi.
#>
[CmdletBinding()]
param(
    [int]$StressMinutes = 10,
    [int]$MemPasses = 2,
    [double]$MemFraction = 0.85,
    [int]$ExpectSockets = 2,
    [int]$ExpectThreads = 72,
    [int]$ExpectRamGB = 128,
    [int]$ExpectDimms = 4,
    [int]$ExpectDimmGB = 32,
    [string]$ExpectCpu = '2686',
    [string]$ExpectBrand = 'Samsung',
    [switch]$Quick,
    [switch]$SkipTests,
    [switch]$InjectErrors   # chi de tu kiem tra script: co tinh lam sai 1 o RAM + 1 phep tinh CPU
)

$ErrorActionPreference = 'Stop'

trap {
    Write-Host ''
    Write-Host ('SCRIPT BI LOI: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    try { [X99Cpu]::StopAll() } catch {}
    try { Stop-Transcript | Out-Null } catch {}
    exit 2
}

if ($Quick) { $StressMinutes = 1; $MemPasses = 1 }

# ---------------------------------------------------------------------------
# Phan C#: ghim thread vao tung CPU (Windows chia >64 luong thanh nhieu "processor group",
# khong ghim thi chi chay duoc 1 con CPU), test RAM va chay nang CPU.
# Viet theo C# 5 vi Add-Type cua Windows PowerShell 5.1 dung trinh bien dich cu.
# ---------------------------------------------------------------------------
$cs = @'
using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;

public static class X99Native
{
    [StructLayout(LayoutKind.Sequential)]
    public struct GROUP_AFFINITY
    {
        public UIntPtr Mask;
        public ushort Group;
        public ushort R0;
        public ushort R1;
        public ushort R2;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetThreadGroupAffinity(IntPtr hThread, ref GROUP_AFFINITY affinity, IntPtr previous);
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentThread();
    [DllImport("kernel32.dll")]
    public static extern ushort GetActiveProcessorGroupCount();
    [DllImport("kernel32.dll")]
    public static extern uint GetActiveProcessorCount(ushort group);
    [DllImport("kernel32.dll")]
    public static extern bool GetNumaHighestNodeNumber(out uint highest);
    [DllImport("kernel32.dll")]
    public static extern bool GetNumaAvailableMemoryNodeEx(ushort node, out ulong bytes);

    // Moi luong CPU dang chay duoc: {group, index}, xen ke giua cac group (tuc xen ke 2 CPU)
    public static List<int[]> Slots()
    {
        ushort groups = GetActiveProcessorGroupCount();
        var perGroup = new List<List<int[]>>();
        int max = 0;
        for (ushort g = 0; g < groups; g++)
        {
            var l = new List<int[]>();
            uint n = GetActiveProcessorCount(g);
            for (int i = 0; i < (int)n; i++) l.Add(new int[] { g, i });
            perGroup.Add(l);
            if (l.Count > max) max = l.Count;
        }
        var res = new List<int[]>();
        for (int i = 0; i < max; i++)
            foreach (var l in perGroup)
                if (i < l.Count) res.Add(l[i]);
        return res;
    }

    public static bool Pin(int group, int index)
    {
        Thread.BeginThreadAffinity();
        var a = new GROUP_AFFINITY();
        a.Mask = new UIntPtr(1UL << index);
        a.Group = (ushort)group;
        return SetThreadGroupAffinity(GetCurrentThread(), ref a, IntPtr.Zero);
    }
}

public static class X99Cpu
{
    public static volatile bool Stop;
    public static volatile bool Inject;
    public static long Errors;
    public static long Loops;
    static long refBits;
    static readonly List<Thread> threads = new List<Thread>();

    // Phep tinh co dinh: CPU khoe thi lan nao cung ra dung 1 ket qua
    [MethodImpl(MethodImplOptions.NoInlining)]
    public static double Work()
    {
        double x = 1.0;
        long acc = 0;
        for (int i = 1; i <= 300000; i++)
        {
            x = Math.Sqrt(x * 1.000001 + i) + Math.Sin(i * 0.001);
            acc = ((acc << 7) | (long)((ulong)acc >> 57)) ^ ((long)(x * 1000.0) + i);
        }
        return x + (double)(acc & 0xFFFFFF);
    }

    public static int Start()
    {
        Stop = false; Errors = 0; Loops = 0;
        refBits = BitConverter.DoubleToInt64Bits(Work());
        if (Inject) refBits ^= 1;
        threads.Clear();
        foreach (int[] s in X99Native.Slots())
        {
            int g = s[0];
            int idx = s[1];
            var t = new Thread(() =>
            {
                X99Native.Pin(g, idx);
                while (!Stop)
                {
                    long bits = BitConverter.DoubleToInt64Bits(Work());
                    if (bits != refBits) Interlocked.Increment(ref Errors);
                    Interlocked.Increment(ref Loops);
                }
            });
            t.IsBackground = true;
            t.Priority = ThreadPriority.BelowNormal;
            t.Start();
            threads.Add(t);
        }
        return threads.Count;
    }

    public static void StopAll()
    {
        Stop = true;
        foreach (var t in threads) t.Join();
        threads.Clear();
    }
}

public static class X99Mem
{
    public const int ChunkLongs = 1 << 27; // 1 GiB moi chunk
    public static volatile bool Stop;
    public static volatile bool Inject;
    public static volatile bool Done;
    public static volatile int Pass;
    public static volatile int Pattern;
    public static volatile string Phase = "";
    public static long Errors;
    public static long BytesAllocated;
    static readonly List<string> Log = new List<string>();
    static ulong[][] chunks;
    const ulong K = 0x9E3779B97F4A7C15UL;

    public static void StartAsync(int gb, int passes)
    {
        Done = false; Stop = false; Errors = 0; BytesAllocated = 0; Pass = 0; Pattern = 0; Phase = "alloc";
        lock (Log) Log.Clear();
        var t = new Thread(() => Run(gb, passes));
        t.IsBackground = true;
        t.Start();
    }

    public static string[] GetLog()
    {
        lock (Log) return Log.ToArray();
    }

    static void Run(int gb, int passes)
    {
        try
        {
            var slots = X99Native.Slots();
            int w = slots.Count;
            chunks = new ulong[gb][];
            var barrier = new Barrier(w);
            var ths = new List<Thread>();
            for (int i = 0; i < w; i++)
            {
                int wid = i;
                int g = slots[i][0];
                int idx = slots[i][1];
                var th = new Thread(() => Worker(wid, w, g, idx, gb, passes, barrier));
                th.IsBackground = true;
                th.Start();
                ths.Add(th);
            }
            foreach (var th in ths) th.Join();
        }
        catch (Exception e)
        {
            lock (Log) Log.Add("EXCEPTION: " + e.Message);
        }
        finally
        {
            chunks = null;
            GC.Collect();
            Done = true;
        }
    }

    // Moi worker ghim vao 1 luong CPU, tu cap phat chunk cua minh (RAM nam gan CPU do),
    // ghi mau, roi doc lai chunk cua worker ben canh (thuong nam o CPU kia).
    static void Worker(int wid, int w, int g, int idx, int gb, int passes, Barrier b)
    {
        X99Native.Pin(g, idx);
        for (int c = wid; c < gb; c += w)
        {
            try
            {
                chunks[c] = new ulong[ChunkLongs];
                Interlocked.Add(ref BytesAllocated, (long)ChunkLongs * 8);
            }
            catch (OutOfMemoryException)
            {
                chunks[c] = null;
            }
        }
        b.SignalAndWait();
        int verifyStart = (w > 1) ? (wid + 1) % w : wid;
        for (int pass = 1; pass <= passes; pass++)
        {
            for (int p = 0; p < 6; p++)
            {
                if (wid == 0) { Pass = pass; Pattern = p + 1; Phase = "write"; }
                if (!Stop)
                    for (int c = wid; c < gb; c += w)
                        if (chunks[c] != null) Fill(chunks[c], c, p);
                if (Inject && wid == 0 && pass == 1 && p == 0 && gb > 0 && chunks[0] != null)
                    chunks[0][12345] ^= 0x10UL;
                b.SignalAndWait();
                if (wid == 0) Phase = "verify";
                if (!Stop)
                    for (int c = verifyStart; c < gb; c += w)
                        if (chunks[c] != null) Verify(chunks[c], c, p);
                b.SignalAndWait();
            }
        }
    }

    static ulong Const(int p)
    {
        switch (p)
        {
            case 0: return 0UL;
            case 1: return ulong.MaxValue;
            case 2: return 0x5555555555555555UL;
            default: return 0xAAAAAAAAAAAAAAAAUL;
        }
    }

    static void Fill(ulong[] a, int c, int p)
    {
        if (p < 4)
        {
            ulong v = Const(p);
            for (int i = 0; i < a.Length; i++) a[i] = v;
        }
        else
        {
            ulong inv = (p == 5) ? ulong.MaxValue : 0UL;
            ulong basev = (ulong)c << 32;
            for (int i = 0; i < a.Length; i++) a[i] = ((basev | (uint)i) * K) ^ inv;
        }
    }

    static void Verify(ulong[] a, int c, int p)
    {
        long errs = 0;
        if (p < 4)
        {
            ulong v = Const(p);
            for (int i = 0; i < a.Length; i++)
                if (a[i] != v) { errs++; Record(c, i, v, a[i]); }
        }
        else
        {
            ulong inv = (p == 5) ? ulong.MaxValue : 0UL;
            ulong basev = (ulong)c << 32;
            for (int i = 0; i < a.Length; i++)
            {
                ulong e = ((basev | (uint)i) * K) ^ inv;
                if (a[i] != e) { errs++; Record(c, i, e, a[i]); }
            }
        }
        if (errs > 0) Interlocked.Add(ref Errors, errs);
    }

    static void Record(int c, int i, ulong expect, ulong got)
    {
        if (Log.Count >= 20) return;
        lock (Log)
        {
            if (Log.Count < 20)
                Log.Add(string.Format("GB thu {0}, offset 0x{1:X}: ghi {2:X16} doc ra {3:X16} (bit lech {4:X16})",
                    c, (long)i * 8, expect, got, expect ^ got));
        }
    }
}
'@

# ---------------------------------------------------------------------------
$script:Issues = New-Object 'System.Collections.Generic.List[string]'
$script:Warns = New-Object 'System.Collections.Generic.List[string]'

function Write-Section([string]$Title) { Write-Host ''; Write-Host ('== ' + $Title + ' ==') -ForegroundColor Cyan }
function Write-Ok([string]$Msg) { Write-Host ('  [OK]    ' + $Msg) -ForegroundColor Green }
function Write-Bad([string]$Msg) { Write-Host ('  [LOI]   ' + $Msg) -ForegroundColor Red; $script:Issues.Add($Msg) }
function Write-Warn([string]$Msg) { Write-Host ('  [CHU Y] ' + $Msg) -ForegroundColor Yellow; $script:Warns.Add($Msg) }
function Write-Info([string]$Msg) { Write-Host ('          ' + $Msg) }

function Get-EventCount([string]$Provider, [int[]]$Ids, [datetime]$Since) {
    $f = @{ LogName = 'System'; ProviderName = $Provider; StartTime = $Since }
    if ($Ids) { $f['Id'] = $Ids }
    try { return @(Get-WinEvent -FilterHashtable $f -ErrorAction Stop).Count } catch { return 0 }
}

function Get-DimmInfo($d) {
    $pn = ('' + $d.PartNumber).Trim()
    $mf = ('' + $d.Manufacturer).Trim()
    $brand = ''
    $kind = ''
    if ($pn -match '^M3(93|86|78|91)') {
        $brand = 'Samsung'
        $kind = @{ '93' = 'RDIMM'; '86' = 'LRDIMM'; '78' = 'UDIMM'; '91' = 'UDIMM-ECC' }[$Matches[1]]
    }
    elseif ($pn -match '^HMA\w{3}([RLU])') {
        $brand = 'SK Hynix'
        $kind = @{ 'R' = 'RDIMM'; 'L' = 'LRDIMM'; 'U' = 'UDIMM' }[$Matches[1]]
    }
    elseif ($pn -match '^\d{1,2}AS[FS]\w*?72([PLA])Z') {
        $brand = 'Micron'
        $kind = @{ 'P' = 'RDIMM'; 'L' = 'LRDIMM'; 'A' = 'UDIMM' }[$Matches[1]]
    }
    elseif ($pn -match '^(KVR|KSM|KTD|KTH|KTL|KCP)') { $brand = 'Kingston' }

    if (-not $brand) {
        if ($mf -match 'Samsung|^(00|80)?CE') { $brand = 'Samsung' }
        elseif ($mf -match 'Hynix|^(00|80)?AD') { $brand = 'SK Hynix' }
        elseif ($mf -match 'Micron|^(00|80)?2C') { $brand = 'Micron' }
        elseif ($mf -match 'Kingston|^(01|80)?98') { $brand = 'Kingston' }
        elseif ($mf) { $brand = $mf }
        else { $brand = '?' }
    }
    if (-not $kind) {
        $td = [int]$d.TypeDetail
        if ($td -band 32768) { $kind = 'LRDIMM' }
        elseif ($td -band 8192) { $kind = 'RDIMM' }
        elseif ($td -band 16384) { $kind = 'UDIMM' }
        else { $kind = '?' }
    }
    $ddr = switch ([int]$d.SMBIOSMemoryType) { 26 { 'DDR4' } 24 { 'DDR3' } 34 { 'DDR5' } default { '?' } }
    if (-not $pn) { $pn = '(trong)' }
    [pscustomobject]@{ Brand = $brand; Kind = $kind; Part = $pn; DDR = $ddr }
}

function Get-LoadSample {
    $rows = @(Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ProcessorInformation -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*,_Total' })
    foreach ($r in $rows) {
        $nom = [double]$r.ProcessorFrequency
        $perf = [double]$r.PercentProcessorPerformance
        if ($perf -gt 0) { $mhz = [int]($nom * $perf / 100) } else { $mhz = [int]$nom }
        [pscustomobject]@{ Node = $r.Name.Split(',')[0]; Busy = [int]$r.PercentProcessorTime; MHz = $mhz; Nominal = $nom }
    }
}

function Get-AcpiTemp {
    try {
        $t = @(Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop)
        if ($t.Count -eq 0) { return 'n/a' }
        return (($t | ForEach-Object { '{0:N0}C' -f ($_.CurrentTemperature / 10 - 273.15) }) -join '/')
    }
    catch { return 'n/a' }
}

# ---------------------------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$desk = [Environment]::GetFolderPath('Desktop')
if (-not $desk -or -not (Test-Path $desk)) { $desk = $env:TEMP }
$report = Join-Path $desk ("x99-report-$stamp.txt")
try { Start-Transcript -Path $report -Force | Out-Null } catch { $report = $null }

Write-Host ''
Write-Host '=============== X99 DUAL CHECK ===============' -ForegroundColor Cyan
Write-Host ('Mong doi: {0} CPU E5-{1}, {2} luong, {3} thanh RAM {4}GB = {5}GB, hang {6}' -f `
        $ExpectSockets, $ExpectCpu, $ExpectThreads, $ExpectDimms, $ExpectDimmGB, $ExpectRamGB, $ExpectBrand)
if (-not $SkipTests) {
    Write-Host ('Test RAM {0} pass + chay nang CPU {1} phut. Tong cong khoang {2} phut.' -f $MemPasses, $StressMinutes, ($StressMinutes + 2 * $MemPasses + 1))
}

if (-not [Environment]::Is64BitProcess) {
    Write-Host 'Phai chay bang PowerShell 64-bit (dung run.bat).' -ForegroundColor Red
    exit 2
}
$isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not ('X99Mem' -as [type])) { Add-Type -TypeDefinition $cs -Language CSharp }

# --- 1. Windows -------------------------------------------------------------
Write-Section '1. Windows'
$os = Get-CimInstance Win32_OperatingSystem
$isHome = ($os.Caption -match 'Home') -or (@(98, 99, 100, 101) -contains [int]$os.OperatingSystemSKU)
Write-Info ('{0} (build {1})' -f ('' + $os.Caption).Trim(), $os.BuildNumber)
if ($isHome) {
    Write-Warn 'Windows Home chi dung duoc 1 CPU. Neu chi thay 1 CPU thi CHUA CHAC CPU hong: xem trong BIOS hoac boot USB Linux (README).'
}
if (-not $isAdmin) { Write-Warn 'Khong chay quyen Admin, mot so thong tin co the thieu. Nen chay bang run.bat.' }

# --- 2. Main + BIOS ---------------------------------------------------------
Write-Section '2. Main + BIOS'
$bb = Get-CimInstance Win32_BaseBoard
$bios = Get-CimInstance Win32_BIOS
$boardName = ('{0} {1} {2}' -f $bb.Manufacturer, $bb.Product, $bb.Version).Trim()
Write-Info ('Main: ' + $boardName)
$biosDate = ''
if ($bios.ReleaseDate) { $biosDate = ([datetime]$bios.ReleaseDate).ToString('yyyy-MM-dd') }
Write-Info ('BIOS: {0} ({1})' -f $bios.SMBIOSBIOSVersion, $biosDate)
if ($boardName -match 'Default string|To be filled|^OEM|^\s*$') {
    Write-Info '-> Main OEM khong ten tuoi (thuong re hon Huananzhi khoang 1 trieu).'
}

# --- 3. CPU -----------------------------------------------------------------
Write-Section '3. CPU'
$cpus = @(Get-CimInstance Win32_Processor)
foreach ($c in $cpus) {
    Write-Info ('{0}: {1} | {2} nhan / {3} luong | {4} MHz' -f $c.SocketDesignation, ('' + $c.Name).Trim(),
        $c.NumberOfCores, $c.NumberOfLogicalProcessors, $c.MaxClockSpeed)
}
$groups = [X99Native]::GetActiveProcessorGroupCount()
$active = [int][X99Native]::GetActiveProcessorCount([uint16]65535)
Write-Info ('Windows dang dung {0} luong ({1} processor group)' -f $active, $groups)

$sockets = $cpus.Count
if ($sockets -ge $ExpectSockets) { Write-Ok ('Nhan {0} CPU' -f $sockets) }
elseif ($isHome) { Write-Warn ('Windows chi thay {0}/{1} CPU (co the do Windows Home) -> kiem tra lai trong BIOS hoac Linux' -f $sockets, $ExpectSockets) }
else { Write-Bad ('Chi nhan {0}/{1} CPU -> CPU, chan socket hoac main co van de' -f $sockets, $ExpectSockets) }

$wrongCpu = @($cpus | Where-Object { ('' + $_.Name) -notmatch $ExpectCpu })
if ($wrongCpu.Count -eq 0) { Write-Ok ('Dung CPU E5-{0}' -f $ExpectCpu) }
else { Write-Bad ('CPU khong phai E5-{0}: {1}' -f $ExpectCpu, (($wrongCpu | ForEach-Object { ('' + $_.Name).Trim() }) -join ', ')) }

if ($active -ge $ExpectThreads) { Write-Ok ('Du {0} luong' -f $active) }
elseif ($isHome -and $active -ge [math]::Floor($ExpectThreads / $ExpectSockets)) {
    Write-Warn ('Chi chay {0}/{1} luong vi Windows Home -> CPU thu 2 chua test duoc tren Windows nay' -f $active, $ExpectThreads)
}
else { Write-Bad ('Chi co {0}/{1} luong (thieu CPU, hoac Hyper-Threading bi tat trong BIOS)' -f $active, $ExpectThreads) }

# --- 4. RAM -----------------------------------------------------------------
Write-Section '4. RAM'
$dimms = @(Get-CimInstance Win32_PhysicalMemory)
$rows = @(foreach ($d in $dimms) {
        $di = Get-DimmInfo $d
        [pscustomobject]@{
            Khe     = ('{0} {1}' -f $d.DeviceLocator, $d.BankLabel).Trim()
            GB      = [math]::Round([double]$d.Capacity / 1GB)
            Hang    = $di.Brand
            Ma      = $di.Part
            Loai    = $di.Kind
            DDR     = $di.DDR
            Bus     = $d.Speed
            DangChay = $d.ConfiguredClockSpeed
        }
    })
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$totalGB = ($rows | Measure-Object -Property GB -Sum).Sum
if (-not $totalGB) { $totalGB = 0 }
$visibleGB = [math]::Round([double]$os.TotalVisibleMemorySize / 1MB, 1)

if ($rows.Count -eq $ExpectDimms) { Write-Ok ('Du {0} thanh RAM' -f $rows.Count) }
else { Write-Bad ('Thay {0} thanh RAM, mong doi {1}' -f $rows.Count, $ExpectDimms) }

$wrongSize = @($rows | Where-Object { $_.GB -ne $ExpectDimmGB })
if ($wrongSize.Count -gt 0) { Write-Bad ('Co {0} thanh khong phai {1}GB: {2}' -f $wrongSize.Count, $ExpectDimmGB, (($wrongSize | ForEach-Object { '{0}GB' -f $_.GB }) -join ', ')) }

if ($totalGB -ge $ExpectRamGB) { Write-Ok ('Tong {0}GB, Windows dung duoc {1}GB' -f $totalGB, $visibleGB) }
else { Write-Bad ('Tong RAM chi {0}GB (mong doi {1}GB)' -f $totalGB, $ExpectRamGB) }

$parts = @($rows | ForEach-Object { $_.Ma } | Sort-Object -Unique)
if ($parts.Count -le 1) { Write-Ok ('Cac thanh cung ma: {0}' -f ($parts -join '')) }
else { Write-Warn ('RAM khong dong bo, {0} ma khac nhau: {1}' -f $parts.Count, ($parts -join ', ')) }

$kinds = @($rows | ForEach-Object { $_.Loai } | Sort-Object -Unique)
if (($kinds -contains 'RDIMM') -and ($kinds -contains 'LRDIMM')) { Write-Bad 'Tron RDIMM voi LRDIMM -> khong chay chung duoc' }
elseif (($kinds -contains 'UDIMM') -or ($kinds -contains 'UDIMM-ECC')) { Write-Warn 'Co thanh UDIMM (khong phai ECC REG nhu nguoi ban noi)' }
elseif ($kinds -contains '?') { Write-Info ('Loai RAM: khong doc duoc het, xem tem (-R = RDIMM, -L = LRDIMM). Doc duoc: ' + ($kinds -join ', ')) }
else { Write-Ok ('Loai: ' + ($kinds -join ', ')) }

$otherBrand = @($rows | Where-Object { $_.Hang -notmatch $ExpectBrand })
if ($otherBrand.Count -eq 0) { Write-Ok ('Hang: ' + $ExpectBrand) }
else { Write-Warn ('Co {0} thanh khong phai {1}: {2}' -f $otherBrand.Count, $ExpectBrand, (($otherBrand | ForEach-Object { $_.Hang } | Sort-Object -Unique) -join ', ')) }

if (@($rows | Where-Object { $_.DDR -eq 'DDR3' }).Count -gt 0) { Write-Warn 'RAM la DDR3, khong phai DDR4' }
$speeds = @($rows | Where-Object { $_.Bus } | ForEach-Object { [int]$_.Bus })
if ($speeds.Count -gt 0) {
    $minSpeed = ($speeds | Measure-Object -Minimum).Minimum
    if ($minSpeed -lt 2133) { Write-Warn ('Co thanh bus {0} (thap hon 2133)' -f $minSpeed) }
}

$hi = [uint32]0
if ([X99Native]::GetNumaHighestNodeNumber([ref]$hi)) {
    $nodeCount = [int]$hi + 1
    $nodeInfo = @(for ($n = 0; $n -lt $nodeCount; $n++) {
            $b = [uint64]0
            [void][X99Native]::GetNumaAvailableMemoryNodeEx([uint16]$n, [ref]$b)
            [pscustomobject]@{ Node = $n; FreeGB = [math]::Round($b / 1GB, 1) }
        })
    Write-Info ('RAM trong theo tung CPU: ' + (($nodeInfo | ForEach-Object { 'CPU{0} {1}GB' -f $_.Node, $_.FreeGB }) -join ' | '))
    if ($nodeCount -ge 2) {
        $empty = @($nodeInfo | Where-Object { $_.FreeGB -lt 2 })
        if ($empty.Count -gt 0) { Write-Warn 'Co CPU khong co RAM rieng -> nen cam moi CPU 2 thanh' }
        else { Write-Ok 'RAM chia cho ca 2 CPU' }
    }
    elseif ($sockets -ge 2) { Write-Info 'NUMA dang tat trong BIOS (khong sao).' }
}

# --- 5. Lich su loi ----------------------------------------------------------
Write-Section '5. Lich su loi trong log Windows (90 ngay)'
$since = (Get-Date).AddDays(-90)
$wheaOld = Get-EventCount 'Microsoft-Windows-WHEA-Logger' $null $since
$bsodOld = Get-EventCount 'Microsoft-Windows-WER-SystemErrorReporting' @(1001) $since
$kpOld = Get-EventCount 'Microsoft-Windows-Kernel-Power' @(41) $since
Write-Info ('Loi phan cung (WHEA): {0} | Man hinh xanh: {1} | Tat may dot ngot: {2}' -f $wheaOld, $bsodOld, $kpOld)
if ($wheaOld -gt 0) { Write-Warn ('Windows tung ghi {0} loi phan cung (WHEA) -> hoi nguoi ban' -f $wheaOld) }
if ($bsodOld -gt 0) { Write-Warn ('May tung bi man hinh xanh {0} lan -> hoi nguoi ban' -f $bsodOld) }
if ($kpOld -gt 0) { Write-Info ('(Tat dot ngot co the chi do rut dien/bam nut nguon, khong han la loi)') }
if ($wheaOld -eq 0 -and $bsodOld -eq 0) { Write-Ok 'Khong co loi phan cung / man hinh xanh trong log' }

# --- 6 + 7. Test --------------------------------------------------------------
if ($SkipTests) {
    Write-Section '6. Test RAM + CPU: BO QUA (-SkipTests)'
}
else {
    $mark = Get-Date

    Write-Section '6. Test RAM (ghi roi doc lai)'
    $freeGB = [math]::Floor([double](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB)
    $testGB = [int]([math]::Floor($freeGB * $MemFraction)) - 1
    if ($testGB -lt 1) {
        Write-Warn 'Khong du RAM trong de test'
    }
    else {
        Write-Info ('Test {0}GB tren {1}GB dang trong, {2} pass x 6 mau.' -f $testGB, $freeGB, $MemPasses)
        [X99Mem]::Inject = [bool]$InjectErrors
        [X99Mem]::StartAsync($testGB, $MemPasses)
        $names = @('', '0x00', '0xFF', '0x55', '0xAA', 'theo dia chi', 'dia chi dao')
        $phaseVi = @{ 'alloc' = 'cap phat'; 'write' = 'ghi'; 'verify' = 'doc lai' }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $last = ''
        while (-not [X99Mem]::Done) {
            Start-Sleep -Milliseconds 500
            $pa = [X99Mem]::Pass
            $pt = [X99Mem]::Pattern
            $ph = [X99Mem]::Phase
            $st = '{0}|{1}|{2}' -f $pa, $pt, $ph
            if ($st -ne $last) {
                $last = $st
                if ($pa -gt 0) {
                    Write-Info ('{0,5:N0}s  pass {1}/{2}  mau {3,-12} {4,-8} da cap phat {5}GB  loi: {6}' -f $sw.Elapsed.TotalSeconds,
                        $pa, $MemPasses, $names[$pt], $phaseVi[$ph], [math]::Round([X99Mem]::BytesAllocated / 1GB), [X99Mem]::Errors)
                }
                else { Write-Info 'dang cap phat RAM...' }
            }
        }
        $allocGB = [math]::Round([X99Mem]::BytesAllocated / 1GB)
        $memLog = [X99Mem]::GetLog()
        $memErr = [X99Mem]::Errors
        if (@($memLog | Where-Object { $_ -like 'EXCEPTION*' }).Count -gt 0) { Write-Warn ('Test RAM bi ngat: ' + ($memLog -join '; ')) }
        if ($allocGB -lt $testGB) { Write-Warn ('Chi cap phat duoc {0}/{1}GB de test' -f $allocGB, $testGB) }
        if ($memErr -gt 0) {
            Write-Bad ('RAM SAI DU LIEU: {0} o nho doc ra khac luc ghi -> co thanh RAM loi' -f $memErr)
            foreach ($l in $memLog) { Write-Info $l }
        }
        else { Write-Ok ('Da test {0}GB x {1} pass x 6 mau: khong sai o nao ({2:N0}s)' -f $allocGB, $MemPasses, $sw.Elapsed.TotalSeconds) }
    }

    Write-Section ('7. Chay nang CPU {0} phut' -f $StressMinutes)
    [X99Cpu]::Inject = [bool]$InjectErrors
    $n = [X99Cpu]::Start()
    Write-Info ('Dang chay {0} luong. Trong luc nay may KHONG duoc tat, treo hay man hinh xanh.' -f $n)
    Write-Info 'Muon xem nhiet do that: mo them HWiNFO64 / Core Temp (xem README).'
    if ($StressMinutes -le 1) { $interval = 5 } else { $interval = 10 }
    $end = (Get-Date).AddMinutes($StressMinutes)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $minRatio = 10.0
    $samples = 0
    $lowBusy = 0
    while ((Get-Date) -lt $end) {
        Start-Sleep -Seconds $interval
        $samples++
        $load = @(Get-LoadSample)
        $loadText = (($load | ForEach-Object { 'CPU{0} {1,3}% {2,4}MHz' -f $_.Node, $_.Busy, $_.MHz }) -join ' | ')
        Write-Info ('{0:mm\:ss} | {1} | nhiet ACPI: {2} | tinh sai: {3}' -f $sw.Elapsed, $loadText, (Get-AcpiTemp), [X99Cpu]::Errors)
        if ($samples -ge 2) {
            foreach ($l in $load) {
                if ($l.Busy -ge 90 -and $l.Nominal -gt 0) {
                    $r = $l.MHz / $l.Nominal
                    if ($r -lt $minRatio) { $minRatio = $r }
                }
                if ($l.Busy -lt 80) { $lowBusy++ }
            }
        }
    }
    [X99Cpu]::StopAll()
    $cpuErr = [X99Cpu]::Errors
    if ($cpuErr -gt 0) { Write-Bad ('CPU TINH SAI {0} lan khi chay nang -> CPU/main/nguon khong on dinh' -f $cpuErr) }
    else { Write-Ok ('Chay nang {0} phut, {1:N0} lan tinh, khong sai lan nao' -f $StressMinutes, [X99Cpu]::Loops) }
    if ($minRatio -lt 10) {
        if ($minRatio -lt 0.85) { Write-Warn ('Xung CPU tut con {0:P0} xung goc khi chay nang -> co the qua nhiet, tan kem, hoac main/nguon yeu' -f $minRatio) }
        else { Write-Ok ('Xung on dinh khi chay nang (thap nhat {0:P0} xung goc)' -f $minRatio) }
    }
    if ($lowBusy -gt 0) { Write-Warn 'Co luc CPU khong chay het tai (duoi 80%)' }

    Write-Section '8. Loi phan cung trong luc test'
    $wheaNew = Get-EventCount 'Microsoft-Windows-WHEA-Logger' $null $mark
    if ($wheaNew -gt 0) { Write-Bad ('Windows ghi {0} loi phan cung (WHEA) trong luc test -> thuong la RAM/CPU co van de (ECC da sua tam)' -f $wheaNew) }
    else { Write-Ok 'Khong co loi phan cung (WHEA/ECC) nao trong luc test' }
}

# --- Tong ket -----------------------------------------------------------------
Write-Section 'TONG KET'
if ($script:Issues.Count -eq 0 -and $script:Warns.Count -eq 0) { Write-Host '  KHONG THAY LOI.' -ForegroundColor Green }
foreach ($m in $script:Issues) { Write-Host ('  [LOI]   ' + $m) -ForegroundColor Red }
foreach ($m in $script:Warns) { Write-Host ('  [CHU Y] ' + $m) -ForegroundColor Yellow }
Write-Host ''
Write-Host '  Nho: trong luc test ma may TAT NGANG / TREO / MAN HINH XANH thi do la loi nang nhat.'
Write-Host '  Nho: chup tem 4 thanh RAM va nhin main bang mat (README).'
if ($report) { Write-Host ('  Bao cao da luu: ' + $report) }
try { Stop-Transcript | Out-Null } catch {}
if ($script:Issues.Count -gt 0 -or $script:Warns.Count -gt 0) { exit 1 }
exit 0
