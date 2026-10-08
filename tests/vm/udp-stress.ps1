#Requires -Version 7.0
<#
.SYNOPSIS
  Endgame-style UDP stress test of a test VM, run from the host.
  Profile (research 2026-10): Fortnite ticks at 30 Hz with <=1024 B UE packets; a heavy
  endgame is ~30-600 pps, so 600 pps = heavy endgame, 10k/40k pps = download-like floods.
  Per rate: the host floods the guest with <Size>-byte UDP packets at <rate> pps while a
  60 Hz UDP echo "ping" runs alongside. Guest side (udp-sink.ps1) counts packets and samples
  CPU. Reports received/loss, guest CPU total/DPC/interrupt, busiest-core DPC, and echo
  RTT p50/p99/jitter/loss under load. Host<->guest goes over the Hyper-V switch, so it
  measures the guest's network stack (netvsc, RSS, firewall, VBS), not the physical NIC.
.EXAMPLE
  pwsh tests/vm/udp-stress.ps1 -VMName MuulfzOSFN-Test -User tester -Password 123 -Label v5
#>
param([string] $VMName = 'MuulfzOSFN-Test', [string] $User = 'tester', [string] $Password = 'MuulfzTest!1',
      [int[]] $Rates = @(0, 600, 10000, 40000), [int] $Size = 1000, [int] $Seconds = 20, [int] $EchoHz = 60)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Diagnostics; using System.Net;
using System.Net.Sockets; using System.Threading; using System.Threading.Tasks;
public class UdpRun { public long Sent; public double[] Rtt; }
public static class UdpLoad {
    static long Send(string ip, int pps, int size, int seconds) {
        var c = new UdpClient(); c.Connect(ip, 40000); var buf = new byte[size];
        var sw = Stopwatch.StartNew(); long sent = 0, total = (long)pps * seconds;
        while (sent < total) {
            long due = Math.Min(total, (long)(sw.Elapsed.TotalSeconds * pps));
            if (sent < due) { c.Send(buf, size); sent++; } else Thread.Yield();
        }
        return sent;
    }
    static double[] Ping(string ip, int hz, int seconds) {   // -1 = lost
        var u = new UdpClient(); u.Connect(ip, 40001); u.Client.ReceiveTimeout = 200;
        var rtt = new List<double>(); var buf = new byte[64]; IPEndPoint ep = null;
        long period = Stopwatch.Frequency / hz;
        for (int i = 0; i < hz * seconds; i++) {
            long t0 = Stopwatch.GetTimestamp(); BitConverter.GetBytes(i).CopyTo(buf, 0); u.Send(buf, buf.Length);
            try { while (BitConverter.ToInt32(u.Receive(ref ep), 0) != i) { } rtt.Add((Stopwatch.GetTimestamp() - t0) * 1000.0 / Stopwatch.Frequency); }
            catch (SocketException) { rtt.Add(-1); }
            while (Stopwatch.GetTimestamp() < t0 + period) Thread.Yield();   // no Sleep: 15.6 ms timer granularity
        }
        return rtt.ToArray();
    }
    public static UdpRun Run(string ip, int pps, int size, int seconds, int hz) {
        var ping = Task.Run(() => Ping(ip, hz, seconds));
        long sent = pps > 0 ? Send(ip, pps, size, seconds) : 0;
        return new UdpRun { Sent = sent, Rtt = ping.Result };
    }
}
'@

function Pct($sorted, $p) { $sorted[[math]::Min($sorted.Count - 1, [math]::Floor($p * $sorted.Count))] }
$cred = [pscredential]::new($User, (ConvertTo-SecureString $Password -AsPlainText -Force))
$ip = (Get-VMNetworkAdapter -VMName $VMName).IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
if (-not $ip) { throw "no IPv4 for $VMName" }
$s = New-PSSession -VMName $VMName -Credential $cred
try {
    Invoke-Command -Session $s -ScriptBlock {      # bench-only rule, removed below
        New-NetFirewallRule -DisplayName MuulfzUdpBench -Direction Inbound -Protocol UDP -LocalPort 40000, 40001 -Action Allow | Out-Null }
    foreach ($rate in $Rates) {
        $job = Invoke-Command -Session $s -FilePath (Join-Path $PSScriptRoot 'udp-sink.ps1') -ArgumentList ($Seconds + 10) -AsJob
        Start-Sleep 6                                   # guest compiles the sink and binds the ports
        $r = [UdpLoad]::Run($ip, $rate, $Size, $Seconds, $EchoHz)
        $g = Receive-Job $job -Wait -AutoRemoveJob
        # CPU only over the seconds the load was actually arriving (idle run: all seconds after start-up)
        $win = if ($rate) { @($g.Samples | Where-Object Pps -ge (0.5 * $rate)) } else { @($g.Samples | Select-Object -Skip 6 -First $Seconds) }
        $seq = @($r.Rtt | Where-Object { $_ -ge 0 })
        $ok = @($seq | Sort-Object)
        $jit = if ($seq.Count -gt 1) { (1..($seq.Count - 1) | ForEach-Object { [math]::Abs($seq[$_] - $seq[$_ - 1]) } | Measure-Object -Average).Average } else { $null }
        $avg = { param($k) [math]::Round((($win | Measure-Object $k -Average).Average), 2) }
        [pscustomobject]@{
            Pps = $rate; Sent = $r.Sent; Received = $g.Received
            LossPct = if ($r.Sent) { [math]::Round(100 * (1 - $g.Received / $r.Sent), 3) } else { 0 }
            CpuPct = & $avg Cpu; DpcPct = & $avg Dpc; IntPct = & $avg Int; MaxCoreDpcPct = & $avg MaxCoreDpc; Seconds = $win.Count
            RttP50Ms = if ($ok) { [math]::Round((Pct $ok 0.5), 3) }; RttP99Ms = if ($ok) { [math]::Round((Pct $ok 0.99), 3) }
            JitterMs = if ($null -ne $jit) { [math]::Round($jit, 3) }; EchoLossPct = [math]::Round(100 * @($r.Rtt | Where-Object { $_ -lt 0 }).Count / $r.Rtt.Count, 2)
        }
    }
} finally {
    # Fresh call: if the session broke, cleanup must not mask the original error.
    Invoke-Command -VMName $VMName -Credential $cred -ErrorAction SilentlyContinue -ScriptBlock { Remove-NetFirewallRule -DisplayName MuulfzUdpBench -ErrorAction SilentlyContinue }
    Remove-PSSession $s
}
