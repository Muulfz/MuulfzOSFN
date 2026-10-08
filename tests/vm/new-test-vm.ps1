#Requires -Version 7.0
<#
.SYNOPSIS
  Create a Hyper-V Gen2 test VM (Secure Boot + vTPM) that installs Windows
  unattended from -IsoPath, then stages AME Beta + the Fortnite .apbx +
  validate-fortnite.ps1 into C:\Test and takes a 'clean-install' checkpoint.

  Needs Hyper-V enabled and an elevated shell (or Hyper-V Administrators).
  Fortnite itself can't be tested here: EAC refuses to run inside VMs.
#>
param(
    [Parameter(Mandatory)] [string] $IsoPath,
    [string] $Name     = 'MuulfzOSFN-Test',
    [string] $VmDir    = 'C:\VMs',
    [string] $User     = 'tester',
    [string] $Password = '123',   # throwaway local account in a throwaway VM; easy to type in vmconnect
    [string] $Apbx     = (Join-Path $PSScriptRoot '..\..\dist\MuulfzOSFN-fortnite.apbx'),
    [int]    $InstallTimeoutMin = 60,
    # AME-injected ISO: attach no answer file. AME ships its own in $OEM$\$$\Panther,
    # which ours would collide with; click Setup by hand, like on the real USB stick.
    # Pass the account AME baked into the image as -User/-Password.
    [switch] $NoUnattend
)
$ErrorActionPreference = 'Stop'
if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "VM '$Name' already exists. Remove-VM it (and $VmDir\$Name) first." }
if (-not (Test-Path $Apbx)) { throw "Missing $Apbx -- run tools/build-apbx-fortnite.ps1 first." }

# 1. Read the ISO's UI language (Setup must get a language its boot image has).
$IsoPath = (Resolve-Path $IsoPath).Path
$mount = Mount-DiskImage -ImagePath $IsoPath -PassThru
try {
    $drive = ($mount | Get-Volume).DriveLetter
    $lang = (Get-Content "${drive}:\sources\lang.ini" | Where-Object { $_ -match '^\s*([a-z]{2}-[a-z]{2,4})\s*=' } |
             Select-Object -First 1) -replace '^\s*([a-z-]+).*', '$1'
} finally { Dismount-DiskImage -ImagePath $IsoPath | Out-Null }
if (-not $lang) { throw "Couldn't read language from sources\lang.ini" }
$lang = [cultureinfo]::GetCultureInfo($lang).Name   # lang.ini says 'en-us'; unattend wants 'en-US'
Write-Host "ISO language: $lang"

# 2. autounattend.xml on a tiny ISO (Setup scans removable read-only media).
$dir = Join-Path $VmDir $Name
New-Item -ItemType Directory -Force -Path "$dir\unattend" | Out-Null
$pw = [Security.SecurityElement]::Escape($Password)
$c = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'
@"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" $c>
      <SetupUILanguage><UILanguage>$lang</UILanguage></SetupUILanguage>
      <InputLocale>$lang</InputLocale><SystemLocale>$lang</SystemLocale><UILanguage>$lang</UILanguage><UserLocale>$lang</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" $c>
      <DiskConfiguration><Disk wcm:action="add"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>
        <CreatePartitions>
          <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
          <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
          <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
        </CreatePartitions>
        <ModifyPartitions>
          <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format></ModifyPartition>
          <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
          <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Letter>C</Letter></ModifyPartition>
        </ModifyPartitions>
      </Disk></DiskConfiguration>
      <ImageInstall><OSImage>
        <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>Windows 11 Pro</Value></MetaData></InstallFrom>
        <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
      </OSImage></ImageInstall>
      <!-- Generic Win11 Pro install key (public, does not activate) -->
      <UserData><AcceptEula>true</AcceptEula><ProductKey><Key>VK7JG-NPHTM-C97JM-9MPGT-3V66T</Key><WillShowUI>Never</WillShowUI></ProductKey></UserData>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $c>
      <InputLocale>$lang</InputLocale><SystemLocale>$lang</SystemLocale><UILanguage>$lang</UILanguage><UserLocale>$lang</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" $c>
      <OOBE><HideEULAPage>true</HideEULAPage><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC></OOBE>
      <UserAccounts><LocalAccounts><LocalAccount wcm:action="add"><Name>$User</Name><Group>Administrators</Group>
        <Password><Value>$pw</Value><PlainText>true</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts>
      <AutoLogon><Enabled>true</Enabled><Username>$User</Username><LogonCount>9999</LogonCount>
        <Password><Value>$pw</Value><PlainText>true</PlainText></Password></AutoLogon>
    </component>
  </settings>
</unattend>
"@ | Set-Content "$dir\unattend\autounattend.xml" -Encoding utf8

# IMAPI2 (built into Windows) -> ISO; no ADK/oscdimg needed.
$fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$fsi.FileSystemsToCreate = 3   # ISO9660 + Joliet
$fsi.Root.AddTree("$dir\unattend", $false)
$stream = $fsi.CreateResultImage().ImageStream
if (-not ('IsoWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.IO; using System.Runtime.InteropServices; using System.Runtime.InteropServices.ComTypes;
public static class IsoWriter {
  public static void Save(object s, string path) {
    var src = (IStream)s; var buf = new byte[65536]; var read = Marshal.AllocHGlobal(4);
    using (var fs = File.Create(path)) {
      while (true) { src.Read(buf, buf.Length, read); int n = Marshal.ReadInt32(read); if (n == 0) break; fs.Write(buf, 0, n); }
    }
    Marshal.FreeHGlobal(read);
  }
}
'@
}
$unattendIso = "$dir\unattend.iso"
[IsoWriter]::Save($stream, $unattendIso)

# 3. Gen2 VM: Secure Boot (MicrosoftWindows template) + vTPM, like a Win11 PC.
$vm = New-VM -Name $Name -Generation 2 -MemoryStartupBytes 16GB -Path $VmDir `
        -NewVHDPath "$dir\$Name.vhdx" -NewVHDSizeBytes 100GB -SwitchName 'Default Switch'
# Nested virtualization: without it VBS can never run in the guest, so the
# "keep VBS on" path would be untestable.
Set-VMProcessor -VM $vm -Count 8 -ExposeVirtualizationExtensions $true
Set-VMMemory -VM $vm -DynamicMemoryEnabled $false
Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -CheckpointType Standard
Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
Set-VMKeyProtector -VM $vm -NewLocalKeyProtector
Enable-VMTPM -VM $vm
$dvd = Add-VMDvdDrive -VM $vm -Path $IsoPath -Passthru
if (-not $NoUnattend) { Add-VMDvdDrive -VM $vm -Path $unattendIso }
Set-VMFirmware -VM $vm -FirstBootDevice $dvd

# 4. Boot and answer "Press any key to boot from CD or DVD" (Enter via Msvm_Keyboard).
Start-VM -VM $vm
$kb = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_Keyboard | Where-Object SystemName -eq $vm.Id.Guid
1..15 | ForEach-Object { Start-Sleep 1; if ($kb) { Invoke-CimMethod -InputObject $kb -MethodName TypeKey -Arguments @{ keyCode = 13 } | Out-Null } }
Write-Host "Installing Windows unattended (watch: vmconnect localhost $Name)..."

# 5. Wait until PowerShell Direct answers with the unattend account.
$cred = [pscredential]::new($User, (ConvertTo-SecureString $Password -AsPlainText -Force))
$deadline = (Get-Date).AddMinutes($InstallTimeoutMin)
do {
    Start-Sleep 30
    $up = try { Invoke-Command -VMName $Name -Credential $cred -ScriptBlock { $true } -ErrorAction Stop } catch { $false }
} until ($up -or (Get-Date) -gt $deadline)
if (-not $up) { throw "Guest not reachable after $InstallTimeoutMin min. Check the console: vmconnect localhost $Name" }
Get-VMDvdDrive -VM $vm | Set-VMDvdDrive -Path $null

# 6. Stage test kit in C:\Test, then checkpoint the clean baseline.
$s = New-PSSession -VMName $Name -Credential $cred
try {
    Invoke-Command -Session $s -ScriptBlock {
        New-Item -ItemType Directory -Force C:\Test | Out-Null
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest 'https://download.ameliorated.io/AME%20Beta.zip' -OutFile C:\Test\AME-Beta.zip
            Expand-Archive C:\Test\AME-Beta.zip C:\Test\AME -Force
        } catch { Write-Warning "AME download failed ($($_.Exception.Message)) -- get it from amelabs.net inside the VM" }
        [Environment]::OSVersion.Version.ToString() + ' UBR ' +
            (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR
    }
    Copy-Item -ToSession $s -Path $Apbx, (Join-Path $PSScriptRoot 'validate-fortnite.ps1') -Destination C:\Test\
} finally { Remove-PSSession $s }
Checkpoint-VM -VM $vm -SnapshotName 'clean-install'
Write-Host "Ready. Checkpoint 'clean-install' taken. Kit in C:\Test (AME, apbx, validator)."
