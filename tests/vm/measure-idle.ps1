<#
.SYNOPSIS
  Idle footprint of the guest, measured at a fixed uptime so runs compare fairly.
  Run inside the VM (admin), e.g. over PowerShell Direct:
    Invoke-Command -VMName MuulfzOSFN-Test -Credential $cred -FilePath tests\vm\measure-idle.ps1 -ArgumentList 5
  FPS / 1% lows can't be measured here (no GPU, EAC blocks VMs) -- use tools/bench on bare metal.
#>
param([int] $AtUptimeMin = 5, [int] $NetWindowSec = 60)
$ErrorActionPreference = 'Stop'

$os = Get-CimInstance Win32_OperatingSystem
$wait = $os.LastBootUpTime.AddMinutes($AtUptimeMin) - (Get-Date)
if ($wait.TotalSeconds -gt 0) { Start-Sleep -Seconds ([int]$wait.TotalSeconds) }

# Background network chatter (telemetry, store, sync) over a quiet window.
$nic = { Get-NetAdapterStatistics | Measure-Object ReceivedBytes, SentBytes -Sum }
$n0 = & $nic; $cpu = [System.Collections.Generic.List[double]]::new()
$t = [System.Diagnostics.Stopwatch]::StartNew()
while ($t.Elapsed.TotalSeconds -lt $NetWindowSec) {
    $cpu.Add((Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime)
    Start-Sleep 2
}
$n1 = & $nic

# Windows' own boot timing (Diagnostics-Performance event 100) for this boot.
$boot = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100; StartTime = $os.LastBootUpTime } -MaxEvents 1 -ErrorAction SilentlyContinue |
    ForEach-Object { $d = @{}; ([xml]$_.ToXml()).Event.EventData.Data | ForEach-Object { $d[$_.Name] = $_.'#text' }; $d }   # mixed: timestamps + ms counters

$os = Get-CimInstance Win32_OperatingSystem
$p = Get-Process
# Epic launcher autostarts on the playbook build only; report it so the OS can be compared alone.
$epic = $p | Where-Object Name -like 'Epic*'
[pscustomobject]@{
    EpicProcesses   = @($epic).Count
    EpicRamMB       = [int](($epic | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
    Processes       = $p.Count
    Threads         = ($p | ForEach-Object { $_.Threads.Count } | Measure-Object -Sum).Sum
    Handles         = ($p | Measure-Object HandleCount -Sum).Sum
    RamUsedMB       = [int](($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1KB)
    CommitMB        = [int](($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1KB)
    ServicesRunning = @(Get-Service | Where-Object Status -eq Running).Count
    AppxPackages    = @(Get-AppxPackage -AllUsers).Count
    CpuBusyPct      = [math]::Round(($cpu | Measure-Object -Average).Average, 2)
    IdleNetRecvKB   = [math]::Round((($n1 | Where-Object Property -eq ReceivedBytes).Sum - ($n0 | Where-Object Property -eq ReceivedBytes).Sum) / 1KB, 1)
    IdleNetSentKB   = [math]::Round((($n1 | Where-Object Property -eq SentBytes).Sum - ($n0 | Where-Object Property -eq SentBytes).Sum) / 1KB, 1)
    BootTimeMs      = if ($boot) { [int64]$boot.BootTime } else { $null }
    BootMainPathMs  = if ($boot) { [int64]$boot.MainPathBootTime } else { $null }
    BootPostBootMs  = if ($boot) { [int64]$boot.BootPostBootTime } else { $null }
    UptimeMin       = [int]((Get-Date) - $os.LastBootUpTime).TotalMinutes
}
