#Requires -Version 7.0
<#
.SYNOPSIS
  A/B benchmark of Hyper-V test VMs (stock Windows vs MuulfzOSFN vs Atlas), same vCPU/RAM/host,
  one VM at a time. Per config: restore checkpoint, pause Windows Update (same for all),
  same autologon, N clean reboots. Each cycle: measure-idle.ps1 at 5 min uptime +
  sysbench.ps1 (network, bufferbloat, timer, 7-Zip), udp-stress.ps1 (endgame-style UDP flood)
  and, with -Game, GPU-P game-bench.ps1 x GameRuns.
  Results -> <OutDir>/<label>-<n>.json
.EXAMPLE
  pwsh tests/vm/bench-compare.ps1 -Set 26h2 -Game
  pwsh tests/vm/bench-compare.ps1 -Set 25h2 -Game -Only 25h2-atlas
#>
param([ValidateSet('26h2', '25h2', 'all')] [string] $Set = '26h2', [int] $Cycles = 3, [string[]] $Only,
      [switch] $Game, [int] $GameRuns = 3, [switch] $SkipUdp, [switch] $SkipCpu, [string] $OutDir)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = if ($OutDir) { $OutDir } else { Join-Path $repo 'benchmarks\vm-compare2' }
New-Item -ItemType Directory -Force $out | Out-Null
$log = Join-Path $out 'run.log'
function Log($m) { $l = "{0:HH:mm:ss} {1}" -f (Get-Date), $m; Write-Host $l; Add-Content $log $l }

$all = @(
    @{ Set = '26h2'; Label = 'stock';           VM = 'MuulfzOSFN-Test'; Checkpoint = 'updated-26h2-9550';     User = 'tester'; Pw = 'MuulfzTest!1'; Vbs = $false; Net = $true }
    # v5 applied live on the same updated-26h2-9550 base as stock.
    @{ Set = '26h2'; Label = 'muulfzosfn';      VM = 'MuulfzOSFN-Test'; Checkpoint = '26h2-muulfzosfn-v5';    User = 'tester'; Pw = 'MuulfzTest!1'; Vbs = $false; Net = $true }
    # v5 + wizard page 3 (service grouping, memory compression off, FTH off), same base.
    @{ Set = '26h2'; Label = 'muulfzosfn-perf'; VM = 'MuulfzOSFN-Test'; Checkpoint = '26h2-muulfzosfn-perf';  User = 'tester'; Pw = 'MuulfzTest!1'; Vbs = $false; Net = $true }
    # Windows default on modern PCs (and auto-enabled from Oct 2026): Memory Integrity on.
    @{ Set = '26h2'; Label = 'stock-vbs';       VM = 'MuulfzOSFN-Test'; Checkpoint = 'updated-26h2-9550';     User = 'tester'; Pw = 'MuulfzTest!1'; Vbs = $true;  Net = $false }
    @{ Set = '25h2'; Label = '25h2-stock';      VM = 'MuulfzOSFN-Test'; Checkpoint = '25h2-26200.9457';       User = 'tester'; Pw = 'MuulfzTest!1'; Vbs = $false; Net = $true }
    @{ Set = '25h2'; Label = '25h2-atlas';      VM = 'MuulfzOSFN-Test'; Checkpoint = '25h2-atlas';            User = 'tester'; Pw = 'MuulfzTest!1'; Vbs = $false; Net = $true }
    @{ Set = '25h2'; Label = '25h2-muulfzosfn'; VM = 'MuulfzOSFN-Test'; Checkpoint = '25h2-muulfzosfn';       User = 'tester'; Pw = 'MuulfzTest!1'; Vbs = $false; Net = $true }
)
$configs = $all | Where-Object { ($Set -eq 'all' -or $_.Set -eq $Set) -and (-not $Only -or $_.Label -in $Only) }

$7zDir = 'C:\Program Files\NVIDIA Corporation\NVIDIA App'
$kit = @((Join-Path $PSScriptRoot 'measure-idle.ps1'), (Join-Path $repo 'tools\bench\sysbench.ps1'), "$7zDir\7z.exe", "$7zDir\7z.dll")
$gameKit = @((Join-Path $repo 'dist\downloads\heaven\Unigine_Heaven-4.0.exe'), (Join-Path $repo 'dist\downloads\presentmon\PresentMon-2.6.0-x64.exe'))
$gpuP = Join-Path $PSScriptRoot 'gpu-p.ps1'

function WaitUp($c, $cred, [datetime] $after) {
    $deadline = (Get-Date).AddMinutes(15)
    do {
        Start-Sleep 10
        $ok = try { Invoke-Command -VMName $c.VM -Credential $cred -ErrorAction Stop -ArgumentList $after -ScriptBlock {
            param($after) ((Get-CimInstance Win32_OperatingSystem).LastBootUpTime -gt $after) -and ((quser 2>$null) -match 'Active') } } catch { $false }
    } until ($ok -or (Get-Date) -gt $deadline)
    if (-not $ok) { throw "$($c.VM) did not come back with a logged-on session" }
}

foreach ($c in $configs) { try {      # one broken config must not cost the other configs' runs
    $cp =(Get-VMSnapshot -VMName $c.VM | Where-Object Name -like $c.Checkpoint | Sort-Object CreationTime | Select-Object -Last 1).Name
    if (-not $cp) { Log "SKIP $($c.Label): no checkpoint like '$($c.Checkpoint)'"; continue }
    Log "=== $($c.Label): $($c.VM) @ $cp (game=$Game)"
    Get-VM | Where-Object State -ne 'Off' | Stop-VM -Force
    & $gpuP -Action Detach -VMName $c.VM | Out-Null                     # checkpoint restore needs no GPU-P
    Restore-VMCheckpoint -VMName $c.VM -Name $cp -Confirm:$false
    if ((Get-VM $c.VM).State -ne 'Running') { Start-VM $c.VM }
    $cred = [pscredential]::new($c.User, (ConvertTo-SecureString $c.Pw -AsPlainText -Force))
    WaitUp $c $cred ([datetime]::MinValue)

    $s = New-PSSession -VMName $c.VM -Credential $cred
    Invoke-Command -Session $s -ScriptBlock { New-Item -ItemType Directory -Force C:\Test\bench\out, C:\Test\game | Out-Null }
    Copy-Item -ToSession $s -Path $kit -Destination C:\Test\bench\ -Force
    if ($Game) { Copy-Item -ToSession $s -Path $gameKit -Destination C:\Test\game\ -Force }
    Invoke-Command -Session $s -ArgumentList $c.User, $c.Pw, $c.Vbs, [bool]$Game -ScriptBlock {
        param($u, $pw, $vbs, $game)
        $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'           # same autologon for every config
        Set-ItemProperty $wl AutoAdminLogon '1'; Set-ItemProperty $wl DefaultUserName $u; Set-ItemProperty $wl DefaultPassword $pw
        $ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'                   # pause updates (Settings > Pause)
        $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); $end = (Get-Date).AddDays(7).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        New-Item $ux -Force | Out-Null
        foreach ($k in 'PauseFeatureUpdatesStartTime', 'PauseQualityUpdatesStartTime', 'PauseUpdatesStartTime') { Set-ItemProperty $ux $k $now }
        foreach ($k in 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesEndTime', 'PauseUpdatesExpiryTime') { Set-ItemProperty $ux $k $end }
        # Stock Balanced powers the display off after 300 s, and then the game presents no
        # frames (PresentMon CSV empty). Same for every config: display + sleep never.
        powercfg /change monitor-timeout-ac 0; powercfg /change standby-timeout-ac 0
        if ($vbs) {
            $dg = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
            Set-ItemProperty $dg EnableVirtualizationBasedSecurity 1 -Type DWord
            New-Item "$dg\Scenarios\HypervisorEnforcedCodeIntegrity" -Force | Out-Null
            Set-ItemProperty "$dg\Scenarios\HypervisorEnforcedCodeIntegrity" Enabled 1 -Type DWord
        }
        if ($game -and -not (Test-Path C:\Test\game\Heaven\bin\Heaven.exe)) {
            Start-Process C:\Test\game\Unigine_Heaven-4.0.exe -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/DIR=C:\Test\game\Heaven' -Wait
        }
    }
    Remove-PSSession $s
    if ($Game) {
        & $gpuP -Action Prepare -VMName $c.VM -User $c.User -Password $c.Pw | Out-Null
        Stop-VM -Name $c.VM -Force                                          # graceful shutdown, then attach GPU-P
        & $gpuP -Action Attach -VMName $c.VM | Out-Null
        Start-VM $c.VM
        WaitUp $c $cred ([datetime]::MinValue)
        $gpuName = Invoke-Command -VMName $c.VM -Credential $cred -ScriptBlock { (Get-CimInstance Win32_VideoController | Where-Object Name -like 'NVIDIA*').Name }
        Log "$($c.Label): GPU in guest = $gpuName"
    }

    for ($n = 1; $n -le $Cycles; $n++) {
        $t0 = (Get-Date).ToUniversalTime()
        Invoke-Command -VMName $c.VM -Credential $cred -ScriptBlock { Restart-Computer -Force }
        Start-Sleep 20
        WaitUp $c $cred $t0.ToLocalTime().AddMinutes(-1)
        Log "$($c.Label) #$n booted; measuring idle at 5 min uptime"
        $idle = Invoke-Command -VMName $c.VM -Credential $cred -FilePath (Join-Path $PSScriptRoot 'measure-idle.ps1') -ArgumentList 5, 60 |
            Select-Object * -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName
        $vbs = Invoke-Command -VMName $c.VM -Credential $cred -ScriptBlock {
            $d = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard
            [pscustomobject]@{ VbsStatus = $d.VirtualizationBasedSecurityStatus; HvciRunning = (@($d.SecurityServicesRunning) -contains 2) } } |
            Select-Object VbsStatus, HvciRunning
        Log "$($c.Label) #$n idle: procs=$($idle.Processes) ram=$($idle.RamUsedMB)MB svc=$($idle.ServicesRunning) boot=$($idle.BootTimeMs)ms vbs=$($vbs.VbsStatus)"
        $label = "$($c.Label)-$n"
        $args7 = @('-Label', $label, '-SevenZip', 'C:\Test\bench\7z.exe', '-OutDir', 'C:\Test\bench\out', '-Samples', '100', '-LoadSeconds', '12')
        # -SkipCpu: no all-core 7-Zip. On the dev host (9950X) that step coincided with two hard
        # hangs (2026-10-08); the host was already unstable before the VMs existed.
        if ($SkipCpu) { $args7 += '-SkipCpu' }
        if (-not $c.Net) { $args7 += @('-SkipLoad', '-Targets', 'gateway') }
        $bench = Invoke-Command -VMName $c.VM -Credential $cred -ArgumentList (, $args7) -ScriptBlock {
            param($a) & powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Test\bench\sysbench.ps1 @a *> $null
            Get-ChildItem C:\Test\bench\out -Filter "$($a[1])-*.json" | Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -Raw }
        $b = $bench | ConvertFrom-Json
        Log "$($c.Label) #$n bench: 7z_mt=$($b.cpu.sevenzip_mips_mt) 7z_1t=$($b.cpu.sevenzip_mips_1t) eu_p50=$($b.net_idle.'ping-eu.ds.on.epicgames.com'.p50)"
        $udp = @()
        if (-not $SkipUdp) {      # endgame-style UDP flood + 60 Hz echo, from the host
            try {
                $udp = & (Join-Path $PSScriptRoot 'udp-stress.ps1') -VMName $c.VM -User $c.User -Password $c.Pw
                Log ("$($c.Label) #$n udp: " + (($udp | ForEach-Object { "$($_.Pps)pps cpu=$($_.CpuPct)% dpc=$($_.DpcPct)% p99=$($_.RttP99Ms)ms loss=$($_.LossPct)%" }) -join ' | '))
            } catch { Log "$($c.Label) #$n udp FAILED: $($_.Exception.Message)" }
        }
        $games = @()
        if ($Game) {
            for ($g = 1; $g -le $GameRuns; $g++) {
                try {
                    $r = Invoke-Command -VMName $c.VM -Credential $cred -FilePath (Join-Path $PSScriptRoot 'game-bench.ps1') `
                            -ArgumentList 20, 40, 1280, 720, 'QUALITY_LOW', 'TESSELLATION_DISABLED', $c.User |
                         Select-Object Frames, AvgFps, Low1PctFps, FrameTimeP99Ms, FrameTimeSdMs
                    $games += $r
                    Log "$($c.Label) #$n game ${g}: avg=$($r.AvgFps) fps 1%low=$($r.Low1PctFps) fps p99=$($r.FrameTimeP99Ms)ms"
                } catch { Log "$($c.Label) #$n game ${g} FAILED: $($_.Exception.Message)" }
            }
        }
        [ordered]@{ config = $c.Label; set = $c.Set; cycle = $n; vm = $c.VM; checkpoint = $cp; idle = $idle; vbs = $vbs; bench = $b; udp = $udp; game = $games } |
            ConvertTo-Json -Depth 8 | Set-Content (Join-Path $out "$label.json") -Encoding utf8
    }
    Stop-VM -Name $c.VM -Force
    if ($Game) { & $gpuP -Action Detach -VMName $c.VM | Out-Null }
} catch { Log "FAIL $($c.Label): $($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)" } }
Get-VM | Where-Object State -ne 'Off' | Stop-VM -Force
Log "DONE"
