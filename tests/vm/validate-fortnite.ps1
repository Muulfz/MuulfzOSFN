<#
.SYNOPSIS
  Run inside the test VM (admin) after MuulfzOSFN applied + rebooted.
  Emits one row per check: Kind (tweak | invariant | info), Check, Expected, Actual, Pass.
  Pass the same options you ticked in AME.
.EXAMPLE
  # from the host, over PowerShell Direct:
  Invoke-Command -VMName MuulfzOSFN-Test -Credential $cred -FilePath tests\vm\validate-fortnite.ps1 `
    -ArgumentList $true, $true, $false, $false, $true | Format-Table Kind, Check, Expected, Actual, Pass
#>
param([bool] $VbsOff = $true, [bool] $HighPriority = $true, [bool] $X3dBalanced = $false, [bool] $WuNoDrivers = $false, [bool] $InstallEpic = $true,
      [bool] $SvcGroup = $false, [bool] $MemCompOff = $false, [bool] $FthOff = $false, [bool] $Wallpaper = $true)
$ErrorActionPreference = 'Stop'   # a failing cmdlet must read as ERR, never as a vacuous PASS

function Reg($path, $name) { (Get-ItemProperty "Registry::$path" -Name $name -ErrorAction SilentlyContinue).$name }
function Check($kind, $check, $expected, [scriptblock] $actual) {
    $a = try { & $actual } catch { "ERR: $($_.Exception.Message)" }
    [pscustomobject]@{ Kind = $kind; Check = $check; Expected = "$expected"; Actual = "$a"
                       Pass = if ($kind -eq 'info') { '' } else { "$a" -eq "$expected" } }
}
function Present($pattern) { [bool](Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue) }
$cv  = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$dg  = 'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard'
$ai  = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
$bcd = bcdedit /enum '{current}' | Out-String
if ($LASTEXITCODE) { $bcd = $null }
function Bcd($rx) { if (-not $bcd) { throw 'bcdedit failed (needs admin)' }; $bcd -match $rx }

# --- tweaks: did each option land? -------------------------------------------
Check tweak 'HVCI Enabled'                   ([int](-not $VbsOff)) { Reg "$dg\Scenarios\HypervisorEnforcedCodeIntegrity" Enabled }
Check tweak 'EnableVirtualizationBasedSecurity' ([int](-not $VbsOff)) { Reg $dg EnableVirtualizationBasedSecurity }
Check tweak 'VBS running (0 off / 2 on)'     $(if ($VbsOff) { 0 } else { 2 }) {
    (Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard).VirtualizationBasedSecurityStatus }
Check tweak 'KernelShadowStacks Enabled'     0 { Reg "$dg\Scenarios\KernelShadowStacks" Enabled }
Check tweak 'Fortnite IFEO CpuPriorityClass' $(if ($HighPriority) { 3 } else { '' }) {
    Reg "$cv\Image File Execution Options\FortniteClient-Win64-Shipping.exe\PerfOptions" CpuPriorityClass }
Check tweak 'ExcludeWUDriversInQualityUpdate' $(if ($WuNoDrivers) { 1 } else { '' }) {
    Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' ExcludeWUDriversInQualityUpdate }
Check tweak 'Power plan is Balanced'         $X3dBalanced { [bool]((powercfg /getactivescheme) -match '381b4222-f694-41f0-9685-ff5bb260df2e') }
Check tweak 'HAGS HwSchMode'                 2 { Reg 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' HwSchMode }
Check tweak 'HKCU DirectXUserGlobalSettings' 'SwapEffectUpgradeEnable=1;VRROptimizeEnable=1;' { Reg 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences' DirectXUserGlobalSettings }
Check tweak 'AI DisableClickToDo'            1 { Reg $ai DisableClickToDo }
Check tweak 'AI DisableSettingsAgent'        1 { Reg $ai DisableSettingsAgent }
Check tweak 'AI AllowRecallEnablement'       0 { Reg $ai AllowRecallEnablement }
Check tweak 'Generative AI app access'       'Deny' { Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\generativeAI' Value }
Check tweak 'Paint DisableCocreator'         1 { Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint' DisableCocreator }
foreach ($p in '*Copilot*', '*BingSearch*', '*WebExperience*', '*WritingAssistant*', '*Edge.GameAssist*', '*Clipchamp*',
           '*OutlookForWindows*', '*MSTeams*', '*Todos*', '*DevHome*', '*QuickAssist*', '*CrossDevice*') {
    Check tweak "Appx removed: $p" $false { Present $p }
}
Check tweak 'Epic launcher installed'        $InstallEpic { [bool](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object DisplayName -eq 'Epic Games Launcher') }
Check tweak 'Promo app installs off'         0 { Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' SilentInstalledAppsEnabled }
# Look at the real pin list: Windows rewrites the AuxilliaryPins flags at first logon.
Check tweak 'No Outlook pin on taskbar'      $false { $f = Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' Favorites; [bool]($f -and [Text.Encoding]::Unicode.GetString([byte[]]$f) -match 'Outlook') }
Check tweak 'Taskbar layout for new users'   $true { Test-Path 'C:\Users\Default\AppData\Local\Microsoft\Windows\Shell\LayoutModification.xml' }
Check tweak 'Edge startup boost off'         0 { Reg 'HKLM\SOFTWARE\Policies\Microsoft\Edge' StartupBoostEnabled }
Check tweak 'Start pins policy set'          $true { (Reg 'HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start' ConfigureStartPins) -match 'GamingApp' }
Check tweak 'Spotlight desktop icon off'     1 { Reg 'HKCU\Software\Policies\Microsoft\Windows\CloudContent' DisableSpotlightCollectionOnDesktop }
# Old onedrive-removal wrote here and left a blank desktop icon (run 4).
Check tweak 'No blank OneDrive desktop icon' $false { Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{018D5C66-4533-4307-9B53-224DE2ED1FE6}' }
Check tweak 'Mouse acceleration off'         '0 0 0' { $m = 'HKCU\Control Panel\Mouse'; '{0} {1} {2}' -f (Reg $m MouseSpeed), (Reg $m MouseThreshold1), (Reg $m MouseThreshold2) }
Check tweak 'Sticky Keys shortcut off'       '506' { Reg 'HKCU\Control Panel\Accessibility\StickyKeys' Flags }
Check tweak 'Game DVR capture off'           0 { Reg 'HKCU\System\GameConfigStore' GameDVR_Enabled }
Check tweak 'Fast Startup off'               0 { Reg 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power' HiberbootEnabled }
Check tweak 'NIC power saving off'           '' { $k = '*EEE', 'EEE', 'AdvancedEEE', 'EnableGreenEthernet', 'GigaLite', 'PowerSavingMode', 'ULPMode', 'LowPowerEnable'
    (Get-NetAdapter -Physical | ForEach-Object { Get-NetAdapterAdvancedProperty -Name $_.Name -ErrorAction SilentlyContinue } |
     Where-Object { $_.RegistryKeyword -in $k -and "$($_.RegistryValue)" -ne '0' } | ForEach-Object { "$($_.Name):$($_.RegistryKeyword)" }) -join ' ' }
Check tweak 'NIC fix re-applied at boot'     $true { [bool](Get-ScheduledTask -TaskPath '\MuulfzOTMZ\' -TaskName 'NIC power saving off' -ErrorAction SilentlyContinue) -and (Test-Path "$env:ProgramData\MuulfzOTMZ\nic-power.ps1") }
Check tweak 'Wi-Fi off while wired'          3 { Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WcmSvc\GroupPolicy' fMinimizeConnections }
Check tweak 'Delivery Optimization HTTP only' 0 { Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' DODownloadMode }
Check tweak 'Fortnite DSCP 46 QoS policy'    46 { (Get-NetQosPolicy -Name MuulfzFortnite -ErrorAction SilentlyContinue).DSCPAction }
Check tweak 'DiagTrack disabled'             'Disabled' { (Get-Service DiagTrack).StartType }
Check tweak 'OneDrive sync blocked'          1 { Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive' DisableFileSyncNGSC }
# The policy alone passed while the uninstall script had silently failed (run 1) -- check the binary.
Check tweak 'OneDrive uninstalled (user)'    $false { Test-Path "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe" }
# v5: only the folder Epic suggests -- no store-wide folders, no launcher process names.
Check tweak 'Defender exclusions'            'C:\Program Files\Epic Games\Fortnite' { $m = Get-MpPreference; (@($m.ExclusionPath) + @($m.ExclusionProcess) | Where-Object { $_ }) -join ' | ' }
# --- v5 background quiet (registry/fortnite-qol.yml, appx/ai-26h2.yml) -------
$wu = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
Check tweak 'WU active hours 10-04'          '1 10 4' { '{0} {1} {2}' -f (Reg $wu SetActiveHours), (Reg $wu ActiveHoursStart), (Reg $wu ActiveHoursEnd) }
Check tweak 'Outlook OOBE updater removed'   $false { Test-Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' }
Check tweak 'Post-update setup nag off'      0 { Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' ScoobeSystemSettingEnabled }
Check tweak 'Telemetry policy'               0 { Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' AllowTelemetry }
Check tweak 'WPBT execution off'             1 { Reg 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager' DisableWpbtExecution }
Check tweak 'Device companion apps off'      1 { Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Device Metadata' PreventDeviceMetadataFromNetwork }
Check tweak 'Maintenance wake-up off'        0 { Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Task Scheduler\Maintenance' WakeUp }
Check tweak 'GameBar PresenceWriter off'     $(if ($X3dBalanced) { 1 } else { 0 }) { Reg 'HKLM\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Gaming.GameBar.PresenceServer.Internal.PresenceWriter' ActivationType }
Check tweak 'Telemetry tasks still enabled'  '' { (Get-ScheduledTask -TaskName UsbCeip, Microsoft-Windows-DiskDiagnosticDataCollector, UsageDataReporting, Proxy, MareBackup, StartupAppTask, PcaPatchDbTask, AnalyzeSystem, QueueReporting, MapsToastTask -ErrorAction SilentlyContinue | Where-Object State -ne 'Disabled' | ForEach-Object TaskName) -join ' ' }
Check tweak 'Notepad AI off'                 1 { Reg 'HKLM\SOFTWARE\Policies\WindowsNotepad' DisableAIFeatures }
Check tweak 'WSAIFabricSvc not Automatic'    $true { $v = Get-Service WSAIFabricSvc -ErrorAction SilentlyContinue; -not $v -or "$($v.StartType)" -ne 'Automatic' }
# --- wizard page 3 (registry/performance-options.yml) --------------------------
$svc = 'HKLM\SYSTEM\CurrentControlSet\Services'
Check tweak 'Services grouped (Schedule)'    $(if ($SvcGroup) { 1 } else { '' }) { Reg "$svc\Schedule" SvcHostSplitDisable }
Check tweak 'Kept split: audio/net/Xbox'     '' { (@('Audiosrv', 'AudioEndpointBuilder', 'Dhcp', 'Dnscache', 'NlaSvc', 'XblAuthManager') |
    Where-Object { (Reg "$svc\$_" SvcHostSplitDisable) -eq 1 }) -join ' ' }
$bigRam = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory -ge 15GB
Check tweak 'Memory compression'             $(-not ($MemCompOff -and $bigRam)) { (Get-MMAgent).MemoryCompression }
Check tweak 'FTH off'                        $FthOff { (Reg 'HKLM\SOFTWARE\Microsoft\FTH' Enabled) -eq 0 }
Check info  'svchost processes'              '' { @(Get-Process svchost).Count }
$wp = 'C:\Windows\Web\Wallpaper\MuulfzOS\wallpaper.jpg'
Check tweak 'MuulfzOS wallpaper'             $Wallpaper { (Test-Path $wp) -and (Reg 'HKCU\Control Panel\Desktop' Wallpaper) -eq $wp }
Check tweak 'MuulfzOS lock screen'           $Wallpaper { (Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' LockScreenImagePath) -eq $wp }
# Desktop-only items (no battery); a VM has none.
$desk = -not (Get-CimInstance Win32_Battery)
Check tweak 'Hibernation off (desktop)'      $desk { $desk -and -not (Test-Path C:\hiberfil.sys) }
Check tweak 'PCIe ASPM off (desktop)'        $(if ($desk) { 0 } else { 'skip' }) { if (-not $desk) { 'skip' } else {
    $q = powercfg /q SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 | Out-String
    [Convert]::ToInt32(([regex]'(?i)AC Power Setting Index:\s*0x([0-9a-f]+)').Match($q).Groups[1].Value, 16) } }

# --- invariants: anti-cheat / tournament prerequisites must survive ----------
Check invariant 'Secure Boot on'             $true { Confirm-SecureBootUEFI }
Check invariant 'TPM ready'                  $true { (Get-Tpm).TpmReady }
# 26H2 may ship no TBS service (only the TPM driver) -- a missing key is fine, Start=4 is not.
Check invariant 'TPM/TBS not disabled'       $true { -not (@(@('TPM', 'TBS') | ForEach-Object { Reg "HKLM\SYSTEM\CurrentControlSet\Services\$_" Start }) -contains 4) }
Check invariant 'MeasuredBoot logs present'  $true { [bool](Get-ChildItem C:\Windows\Logs\MeasuredBoot -Filter *.log -ErrorAction Stop) }
Check invariant 'Defender real-time on'      $true { (Get-MpComputerStatus).RealTimeProtectionEnabled }
Check invariant 'VulnerableDriverBlocklist'  1 { Reg 'HKLM\SYSTEM\CurrentControlSet\Control\CI\Config' VulnerableDriverBlocklistEnable }
Check invariant 'No testsigning/debug/DSE-off' $false { Bcd '(?im)^(testsigning|nointegritychecks|debug)\s+(Yes|Sim|On)' }
Check invariant 'DEP nx OptIn'               $true { Bcd '(?im)^nx\s+OptIn' }
Check invariant 'System ASLR/DEP not OFF'    $true { $m = Get-ProcessMitigation -System; $m.ASLR.BottomUp -ne 'OFF' -and $m.DEP.Enable -ne 'OFF' }
Check invariant 'Windows Update not disabled' $true { (Get-Service wuauserv).StartType -ne 'Disabled' }
Check invariant 'WMI running'                'Running' { (Get-Service Winmgmt).Status }
Check invariant 'Store present'              $true { Present 'Microsoft.WindowsStore' }
Check invariant 'Game Bar present (X3D)'     $true { Present 'Microsoft.XboxGamingOverlay' }

# --- info ---------------------------------------------------------------------
Check info 'Build' '' { '{0}.{1} ({2})' -f (Reg $cv CurrentBuild), (Reg $cv UBR), (Reg $cv DisplayVersion) }
Check tweak 'Setup notes on desktop'         $true { Test-Path "$env:PUBLIC\Desktop\Fortnite - MuulfzOSFN.txt" }
Check info 'Setup notes' '' { (Get-Content "$env:PUBLIC\Desktop\Fortnite - MuulfzOSFN.txt" -ErrorAction SilentlyContinue | Select-Object -Skip 2 -First 6) -join ' | ' }
