<#
.SYNOPSIS
  Before/after system benchmark for the gaming PC. Writes benchmarks/sys/<Label>-<stamp>.json.
    - network: RTT / jitter / loss to the gateway, Cloudflare and Fortnite (Epic ping-*.ds) regions
    - bufferbloat: RTT while the link is saturated (download, then upload) -- the usual home bottleneck
    - timer: Sleep(1) accuracy, default vs timeBeginPeriod(1)
    - cpu: 7-Zip benchmark (multi + single thread) when 7z.exe is found
  FPS / PC latency in Fortnite: tools/bench/run.py (PresentMon) with a replay.
  Inside a VM only cpu/timer are meaningful-ish; NIC tuning must be measured on bare metal.
.EXAMPLE
  pwsh tools/bench/sysbench.ps1 -Label stock
  pwsh tools/bench/sysbench.ps1 -Compare benchmarks/sys/stock-*.json, benchmarks/sys/muulfzosfn-*.json
#>
param(
    [string]   $Label = 'run',
    [string[]] $Targets = @('gateway', '1.1.1.1', 'ping-eu.ds.on.epicgames.com', 'ping-nae.ds.on.epicgames.com'),
    [int]      $Samples = 200,
    [int]      $IntervalMs = 50,
    [int]      $LoadSeconds = 15,
    [string]   $LoadTarget = 'ping-eu.ds.on.epicgames.com',
    [switch]   $SkipLoad,
    [switch]   $SkipCpu,
    [string]   $SevenZip,      # explicit 7z.exe (e.g. copied into a VM)
    [string]   $OutDir,        # default: <repo>\benchmarks\sys
    [string[]] $Compare,
    [switch]   $SelfTest
)
$ErrorActionPreference = 'Stop'

function Stats([double[]] $rtt, [int] $sent) {
    # $rtt: successful round trips in ms; losses are simply missing.
    if (-not $rtt.Count) { return [ordered]@{ loss_pct = 100 } }
    $s = $rtt | Sort-Object
    $pct = { param($p) $s[[math]::Min($s.Count - 1, [math]::Floor($p * $s.Count))] }
    $jit = if ($rtt.Count -gt 1) { (1..($rtt.Count - 1) | ForEach-Object { [math]::Abs($rtt[$_] - $rtt[$_ - 1]) } | Measure-Object -Average).Average } else { 0 }
    [ordered]@{
        loss_pct = [math]::Round(100 * ($sent - $rtt.Count) / $sent, 2)
        min = [math]::Round($s[0], 2); avg = [math]::Round(($rtt | Measure-Object -Average).Average, 2)
        p50 = [math]::Round((& $pct 0.50), 2); p95 = [math]::Round((& $pct 0.95), 2); p99 = [math]::Round((& $pct 0.99), 2)
        max = [math]::Round($s[-1], 2); jitter = [math]::Round($jit, 2)
    }
}

if ($SelfTest) {
    $r = Stats @(10, 12, 10, 30, 10) 6
    if ($r.loss_pct -ne 16.67 -or $r.min -ne 10 -or $r.p50 -ne 10 -or $r.max -ne 30 -or $r.jitter -ne 11) { throw "Stats self-test failed: $($r | ConvertTo-Json -Compress)" }
    'Stats self-test OK'; return
}

if ($Compare) {
    $a, $b = $Compare | ForEach-Object { Get-Item $_ | Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -Raw | ConvertFrom-Json -AsHashtable }
    function Flat($h, $p = '') { foreach ($k in $h.Keys) { if ($h[$k] -is [System.Collections.IDictionary]) { Flat $h[$k] "$p$k." } elseif ($h[$k] -is [ValueType]) { [pscustomobject]@{ Key = "$p$k"; Value = $h[$k] } } } }
    $fa = @{}; Flat $a | ForEach-Object { $fa[$_.Key] = $_.Value }
    Flat $b | Where-Object { $fa.ContainsKey($_.Key) } | ForEach-Object {
        $d = $_.Value - $fa[$_.Key]
        [pscustomobject]@{ Metric = $_.Key; ($a.label) = $fa[$_.Key]; ($b.label) = $_.Value
                           Delta = [math]::Round($d, 2); Pct = if ($fa[$_.Key]) { '{0:+0.0;-0.0}%' -f (100 * $d / $fa[$_.Key]) } else { '' } }
    } | Format-Table -AutoSize
    return
}

function PingSeries([string] $target, [int] $n, [int] $gapMs) {
    $p = [System.Net.NetworkInformation.Ping]::new()
    $sw = [System.Diagnostics.Stopwatch]::new()
    $rtt = [System.Collections.Generic.List[double]]::new()
    for ($i = 0; $i -lt $n; $i++) {
        $sw.Restart(); $r = $p.Send($target, 1000); $sw.Stop()
        if ($r.Status -eq 'Success') { $rtt.Add($sw.Elapsed.TotalMilliseconds) }   # Stopwatch: sub-ms resolution
        Start-Sleep -Milliseconds $gapMs
    }
    Stats $rtt.ToArray() $n
}

$out = [ordered]@{ label = $Label; taken_utc = (Get-Date).ToUniversalTime().ToString('o'); machine = $env:COMPUTERNAME
    os = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | ForEach-Object { "$($_.CurrentBuild).$($_.UBR)" })
    route_if = (Find-NetRoute -RemoteIPAddress 1.1.1.1 | Select-Object -First 1).InterfaceAlias }

# --- network, idle ---------------------------------------------------------------
$gw = (Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Sort-Object RouteMetric | Select-Object -First 1).NextHop
$out.net_idle = [ordered]@{}
foreach ($t in $Targets) {
    $host_ = if ($t -eq 'gateway') { $gw } else { $t }
    Write-Host "ping $t ($host_) x$Samples..."
    $out.net_idle[$t] = PingSeries $host_ $Samples $IntervalMs
}

# --- bufferbloat: RTT while saturating down / up ---------------------------------
if (-not $SkipLoad) {
    $loadJob = {
        param($dir, $sec)
        Add-Type -AssemblyName System.Net.Http
        $c = [System.Net.Http.HttpClient]::new(); $c.Timeout = [timespan]::FromSeconds($sec + 30)
        $sw = [System.Diagnostics.Stopwatch]::StartNew(); $bytes = 0L
        $buf = [byte[]]::new(1MB); $body = [byte[]]::new(16MB)
        while ($sw.Elapsed.TotalSeconds -lt $sec) {
            try {
                if ($dir -eq 'down') {
                    # Cloudflare answers 403 above ~25 MB per request; loop 25 MB chunks.
                    $s = $c.GetStreamAsync('https://speed.cloudflare.com/__down?bytes=25000000').GetAwaiter().GetResult()
                    while ($sw.Elapsed.TotalSeconds -lt $sec -and ($n = $s.Read($buf, 0, $buf.Length)) -gt 0) { $bytes += $n }
                    $s.Dispose()
                } else {
                    $null = $c.PostAsync('https://speed.cloudflare.com/__up', [System.Net.Http.ByteArrayContent]::new($body)).GetAwaiter().GetResult()
                    $bytes += $body.Length
                }
            } catch { Start-Sleep -Milliseconds 200 }
        }
        $bytes * 8 / $sw.Elapsed.TotalSeconds / 1e6
    }
    $out.bufferbloat = [ordered]@{}
    foreach ($dir in 'down', 'up') {
        Write-Host "loaded latency ($dir, ${LoadSeconds}s, 4 streams) to $LoadTarget..."
        $jobs = 1..4 | ForEach-Object { Start-Job -ScriptBlock $loadJob -ArgumentList $dir, $LoadSeconds }   # Start-Job: also on Windows PowerShell 5.1 (stock VMs)
        Start-Sleep -Seconds 2                                   # let TCP ramp up before sampling
        $loaded = PingSeries $LoadTarget ([int](($LoadSeconds - 3) * 1000 / ($IntervalMs + 5))) $IntervalMs
        $mbps = ($jobs | Wait-Job | Receive-Job | Measure-Object -Sum).Sum; $jobs | Remove-Job
        if ($mbps -lt 1) { Write-Warning "$dir load moved no data -- loaded-latency numbers for '$dir' are not valid" }
        $added = [math]::Round($loaded.p95 - $out.net_idle[$LoadTarget].p50, 1)
        # Grades roughly follow the Waveform bufferbloat test (added latency under load).
        $grade = if ($added -lt 5) { 'A+' } elseif ($added -lt 30) { 'A' } elseif ($added -lt 60) { 'B' } elseif ($added -lt 200) { 'C' } else { 'D' }
        $out.bufferbloat[$dir] = [ordered]@{ mbps = [math]::Round($mbps, 1); added_p95_ms = $added; grade = $grade; rtt = $loaded }
    }
}

# --- timer: Sleep(1) accuracy ---------------------------------------------------------
if (-not ('WinMM' -as [type])) { Add-Type -Name WinMM -Namespace '' -MemberDefinition '[DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint p); [DllImport("winmm.dll")] public static extern uint timeEndPeriod(uint p);' }
function SleepAvg { $sw = [System.Diagnostics.Stopwatch]::StartNew(); 1..200 | ForEach-Object { [System.Threading.Thread]::Sleep(1) }; [math]::Round($sw.Elapsed.TotalMilliseconds / 200, 3) }
$out.timer = [ordered]@{ sleep1_default_ms = SleepAvg }
[void][WinMM]::timeBeginPeriod(1); $out.timer.sleep1_period1_ms = SleepAvg; [void][WinMM]::timeEndPeriod(1)

# --- cpu: 7-Zip ---------------------------------------------------------------------
$7z = @($SevenZip, (Get-Command 7z -ErrorAction SilentlyContinue).Source, 'C:\Program Files\7-Zip\7z.exe', 'C:\Program Files\NVIDIA Corporation\NVIDIA App\7z.exe') |
    Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if ($7z -and -not $SkipCpu) {
    $tot = { param($args7) ((& $7z b @args7 | Select-String '^Tot:') -split '\s+')[-1] -as [int] }   # last column = rating (MIPS)
    Write-Host "7-Zip benchmark..."
    $out.cpu = [ordered]@{ sevenzip_mips_mt = & $tot @(); sevenzip_mips_1t = & $tot @('-mmt1') }
}

$dir = if ($OutDir) { $OutDir } else { Join-Path $PSScriptRoot '..\..\benchmarks\sys' }
New-Item -ItemType Directory -Force $dir | Out-Null
$file = Join-Path $dir ("{0}-{1:yyyyMMdd-HHmm}.json" -f $Label, (Get-Date))
$out | ConvertTo-Json -Depth 6 | Set-Content $file -Encoding utf8
$out | ConvertTo-Json -Depth 6
Write-Host "saved $file"
