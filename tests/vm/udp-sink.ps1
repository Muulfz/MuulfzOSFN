<#
.SYSTEM
  Guest side of udp-stress.ps1 (runs inside the VM, Windows PowerShell 5.1).
  UDP sink on 40000 (counts packets), UDP echo on 40001 (ping replies), and one CPU
  sample per second: total / DPC / interrupt time and the busiest core's DPC time
  (shows whether network DPCs pile up on one core, i.e. RSS spread).
#>
param([int] $Seconds = 30)
Add-Type -TypeDefinition @'
using System; using System.Net; using System.Net.Sockets; using System.Threading;
public static class UdpSink {
    public static long Count;
    // An ICMP port-unreachable makes the next Receive throw ConnectionReset; unhandled on a
    // background thread that kills the whole process (PS Direct reports "socket target ended").
    static UdpClient Open(int port) {
        var u = new UdpClient(port); u.Client.ReceiveBufferSize = 1 << 20;
        u.Client.IOControl(-1744830452, new byte[] { 0 }, null);   // SIO_UDP_CONNRESET off
        return u;
    }
    static void Sink() {
        var u = Open(40000); var ep = new IPEndPoint(IPAddress.Any, 0);
        while (true) { try { u.Receive(ref ep); Interlocked.Increment(ref Count); } catch (SocketException) { } }
    }
    static void Echo() {
        var u = Open(40001); var ep = new IPEndPoint(IPAddress.Any, 0);
        while (true) { try { var b = u.Receive(ref ep); u.Send(b, b.Length, ep); } catch (SocketException) { } }
    }
    static bool started;
    public static void Start() {      // once per process: the session is reused across rates
        Interlocked.Exchange(ref Count, 0);
        if (started) return;
        started = true;
        new Thread(Sink) { IsBackground = true }.Start();
        new Thread(Echo) { IsBackground = true }.Start();
    }
}
'@
[UdpSink]::Start()
$ctr = '\Processor Information(*)\% Processor Time', '\Processor Information(*)\% DPC Time', '\Processor Information(*)\% Interrupt Time'
$samples = for ($i = 0; $i -lt $Seconds; $i++) {
    $c0 = [UdpSink]::Count
    $s = (Get-Counter $ctr -SampleInterval 1 -MaxSamples 1).CounterSamples
    $tot = { param($name) ($s | Where-Object { $_.Path -like "*(_total)\$name" }).CookedValue }
    $cores = $s | Where-Object { $_.Path -like '*% dpc time' -and $_.InstanceName -notmatch '_total' }
    [pscustomobject]@{ Pps = [UdpSink]::Count - $c0; Cpu = & $tot '% processor time'; Dpc = & $tot '% dpc time'
                       Int = & $tot '% interrupt time'; MaxCoreDpc = ($cores | Measure-Object CookedValue -Maximum).Maximum }
}
[pscustomobject]@{ Received = [UdpSink]::Count; Samples = $samples }
