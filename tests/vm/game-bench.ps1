<#
.SYSTEM
  Runs INSIDE a GPU-P test VM (admin, over PowerShell Direct). One game-engine run:
  Unigine Heaven 4.0 (DX11, demo loop) in the interactive session + PresentMon capture.
  Emits avg FPS, 1% low FPS (from the 99th-percentile frame time), frame-time p99/stdev.
  Kit expected in C:\Test\game (Heaven installed to C:\Test\game\Heaven, PresentMon exe).
#>
param([int] $Warmup = 20, [int] $Seconds = 40, [int] $Width = 1280, [int] $Height = 720,
      [string] $Quality = 'QUALITY_LOW', [string] $Tess = 'TESSELLATION_DISABLED', [string] $User)
$ErrorActionPreference = 'Stop'
$bin = 'C:\Test\game\Heaven\bin'
$args_ = "-project_name Heaven -data_path ../ -engine_config ../data/heaven_4.0.cfg -system_script heaven/unigine.cpp " +
         "-sound_app null -video_app direct3d11 -video_multisample 0 -video_fullscreen 0 -video_mode -1 " +
         "-video_width $Width -video_height $Height -extern_define RELEASE,LANGUAGE_EN,$Quality,$Tess"

# The engine must render on the logged-on desktop, so start it through an interactive task.
Get-Process Heaven -ErrorAction SilentlyContinue | Stop-Process -Force
$a = New-ScheduledTaskAction -Execute "$bin\Heaven.exe" -Argument $args_ -WorkingDirectory $bin
$p = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName MuulfzHeaven -Action $a -Principal $p -Force | Out-Null
Start-ScheduledTask MuulfzHeaven
$t = 0; while (-not (Get-Process Heaven -ErrorAction SilentlyContinue) -and $t -lt 60) { Start-Sleep 1; $t++ }
if (-not (Get-Process Heaven -ErrorAction SilentlyContinue)) { throw 'Heaven did not start' }
Start-Sleep $Warmup                          # scene + shader warm-up
if (-not (Get-Process Heaven -ErrorAction SilentlyContinue)) {
    $log = Get-ChildItem "C:\Users\$User\Heaven" -Filter log*.html -ErrorAction SilentlyContinue | Select-Object -First 1
    $tail = if ($log) { ((Get-Content $log.FullName -Raw) -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim() } else { 'no Heaven log' }
    throw "Heaven exited during warm-up: $($tail.Substring([math]::Max(0, $tail.Length - 300)))"
}

$csv = "C:\Test\game\pm-$(Get-Date -Format HHmmss).csv"
$pm = & C:\Test\game\PresentMon-2.6.0-x64.exe --process_name Heaven.exe --output_file $csv --timed $Seconds `
    --terminate_after_timed --no_console_stats --v1_metrics --stop_existing_session 2>&1
Get-Process Heaven -ErrorAction SilentlyContinue | Stop-Process -Force
Unregister-ScheduledTask MuulfzHeaven -Confirm:$false
if (-not (Test-Path $csv)) { throw "PresentMon wrote no CSV (exit $LASTEXITCODE): $($pm -join ' ')" }

$ft = Import-Csv $csv | ForEach-Object { [double]$_.MsBetweenPresents } | Where-Object { $_ -gt 0 }
if (-not $ft) { throw "no frames captured ($csv)" }
$s = $ft | Sort-Object
$p99 = $s[[math]::Min($s.Count - 1, [math]::Floor(0.99 * $s.Count))]
$avg = ($ft | Measure-Object -Average).Average
$sd = [math]::Sqrt((($ft | ForEach-Object { ($_ - $avg) * ($_ - $avg) }) | Measure-Object -Sum).Sum / $ft.Count)
[pscustomobject]@{
    Frames      = $ft.Count
    AvgFps      = [math]::Round(1000 / $avg, 1)
    Low1PctFps  = [math]::Round(1000 / $p99, 1)
    FrameTimeP99Ms = [math]::Round($p99, 2)
    FrameTimeSdMs  = [math]::Round($sd, 2)
    Csv         = $csv
}
