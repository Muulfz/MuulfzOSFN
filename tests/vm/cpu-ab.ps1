#Requires -Version 7.0
<#
.SYNOPSIS
  Focused CPU A/B: each VM restored, rebooted, left to settle until -SettleMin uptime,
  then -Runs x (7-Zip single-thread + multi-thread). One VM at a time.
  Results -> benchmarks/vm-compare/cpu-ab-<label>.json
#>
param([int] $Runs = 5, [int] $SettleMin = 10, [string[]] $Only)
$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$out = Join-Path $repo 'benchmarks\vm-compare'
$7zDir = 'C:\Program Files\NVIDIA Corporation\NVIDIA App'
$configs = @(
    @{ Label = 'stock';      VM = 'MuulfzOSFN-Test'; Checkpoint = 'updated-26h2-9550';     User = 'tester'; Pw = 'MuulfzTest!1' }
    @{ Label = 'muulfzosfn'; VM = 'MuulfzOSFN-ISO4'; Checkpoint = 'iso4-validated-51of51'; User = 'Player'; Pw = '123' }
) | Where-Object { -not $Only -or $_.Label -in $Only }

foreach ($c in $configs) {
    Get-VM | Where-Object State -ne 'Off' | Stop-VM -Force
    Restore-VMCheckpoint -VMName $c.VM -Name $c.Checkpoint -Confirm:$false
    if ((Get-VM $c.VM).State -ne 'Running') { Start-VM $c.VM }
    $cred = [pscredential]::new($c.User, (ConvertTo-SecureString $c.Pw -AsPlainText -Force))
    foreach ($i in 1..60) { try { Invoke-Command -VMName $c.VM -Credential $cred -ErrorAction Stop -ScriptBlock { 1 } | Out-Null; break } catch { Start-Sleep 5 } }
    $s = New-PSSession -VMName $c.VM -Credential $cred
    Invoke-Command -Session $s -ScriptBlock { New-Item -ItemType Directory -Force C:\Test\cpu | Out-Null }
    Copy-Item -ToSession $s -Path "$7zDir\7z.exe", "$7zDir\7z.dll" -Destination C:\Test\cpu\ -Force
    Remove-PSSession $s
    $t0 = Get-Date
    Invoke-Command -VMName $c.VM -Credential $cred -ScriptBlock { Restart-Computer -Force }
    Start-Sleep 30
    foreach ($i in 1..90) { try { if (Invoke-Command -VMName $c.VM -Credential $cred -ErrorAction Stop -ArgumentList $t0 -ScriptBlock { param($t) (Get-CimInstance Win32_OperatingSystem).LastBootUpTime -gt $t.AddMinutes(-1) }) { break } } catch { }; Start-Sleep 10 }
    Write-Host "$($c.Label): booted, settling to $SettleMin min uptime"
    $r = Invoke-Command -VMName $c.VM -Credential $cred -ArgumentList $Runs, $SettleMin -ScriptBlock {
        param($runs, $settle)
        $up = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        $w = $up.AddMinutes($settle) - (Get-Date); if ($w.TotalSeconds -gt 0) { Start-Sleep -Seconds ([int]$w.TotalSeconds) }
        $tot = { param($a) ((& C:\Test\cpu\7z.exe b @a | Select-String '^Tot:') -split '\s+')[-1] -as [int] }
        $plan = (powercfg /getactivescheme) -replace '^.*:\s*', ''
        1..$runs | ForEach-Object { [pscustomobject]@{ run = $_; mips_1t = & $tot @('-mmt1'); mips_mt = & $tot @() } }
        [pscustomobject]@{ plan = $plan; build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | ForEach-Object { "$($_.CurrentBuild).$($_.UBR)" }) }
    }
    $runsOut = @($r | Where-Object { $null -ne $_.run } | Select-Object run, mips_1t, mips_mt)
    $meta = $r | Where-Object { $_.plan } | Select-Object -First 1
    $runsOut | Format-Table -AutoSize | Out-String | Write-Host
    [ordered]@{ config = $c.Label; plan = $meta.plan; build = $meta.build; settle_min = $SettleMin; runs = $runsOut } |
        ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out "cpu-ab-$($c.Label).json") -Encoding utf8
}
Get-VM | Where-Object State -ne 'Off' | Stop-VM -Force
'DONE'
