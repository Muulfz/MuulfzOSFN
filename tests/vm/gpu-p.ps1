#Requires -Version 7.0
<#
.SYNOPSIS
  Hyper-V GPU partitioning (GPU-PV) for benchmark VMs -- same approach as Easy-GPU-PV.
    -Action Prepare : VM running. Copies the host's active NVIDIA driver into the guest
                      (DriverStore folder -> C:\Windows\System32\HostDriverStore\FileRepository,
                      System32/SysWOW64 nv* user-mode files), plus the game-bench kit.
    -Action Attach  : VM off. Adds the GPU partition adapter + MMIO space.
    -Action Detach  : VM off. Removes it (needed before checkpoint restore/create).
  The guest then sees the real GPU (e.g. RTX 5080) for DirectX. Fortnite still can't run
  in a VM (EAC); this is for generic game-engine benchmarks.
#>
param(
    [Parameter(Mandatory)] [ValidateSet('Prepare', 'Attach', 'Detach')] [string] $Action,
    [Parameter(Mandatory)] [string] $VMName,
    [string] $User, [string] $Password,
    [string] $GpuMatch = 'NVIDIA',
    [int] $Percent = 80
)
$ErrorActionPreference = 'Stop'

switch ($Action) {
    'Prepare' {
        $cred = [pscredential]::new($User, (ConvertTo-SecureString $Password -AsPlainText -Force))
        $v = Get-CimInstance Win32_VideoController | Where-Object Name -match $GpuMatch | Select-Object -First 1
        $store = Split-Path (($v.InstalledDisplayDrivers -split ',')[0])
        $s = New-PSSession -VMName $VMName -Credential $cred
        try {
            $dst = "C:\Windows\System32\HostDriverStore\FileRepository\$(Split-Path $store -Leaf)"
            Invoke-Command -Session $s -ArgumentList $dst -ScriptBlock { param($d) New-Item -ItemType Directory -Force $d | Out-Null }
            Copy-Item -ToSession $s -Path "$store\*" -Destination $dst -Recurse -Force
            foreach ($dir in 'System32', 'SysWOW64') {
                $f = Get-ChildItem "C:\Windows\$dir" -File -Filter 'nv*' | Where-Object Extension -in '.dll', '.exe', '.bin'
                if ($f) { Copy-Item -ToSession $s -Path $f.FullName -Destination "C:\Windows\$dir\" -Force }
            }
            "driver $(Split-Path $store -Leaf) copied to $VMName"
        } finally { Remove-PSSession $s }
    }
    'Attach' {
        $gpu = Get-VMHostPartitionableGpu | Where-Object Name -match 'VEN_10DE' | Select-Object -First 1   # NVIDIA
        if (-not $gpu) { throw 'No partitionable NVIDIA GPU on host' }
        Get-VMGpuPartitionAdapter -VMName $VMName -ErrorAction SilentlyContinue | Remove-VMGpuPartitionAdapter
        Set-VM -VMName $VMName -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace 1GB -HighMemoryMappedIoSpace 32GB
        Add-VMGpuPartitionAdapter -VMName $VMName -InstancePath $gpu.Name
        $d = 100 / $Percent
        Set-VMGpuPartitionAdapter -VMName $VMName `
            -MinPartitionVRAM ([math]::Round(1e9 / $d)) -MaxPartitionVRAM ([math]::Round(1e9 / $d)) -OptimalPartitionVRAM ([math]::Round(1e9 / $d)) `
            -MinPartitionEncode ([math]::Round([uint64]::MaxValue / $d)) -MaxPartitionEncode ([math]::Round([uint64]::MaxValue / $d)) -OptimalPartitionEncode ([math]::Round([uint64]::MaxValue / $d)) `
            -MinPartitionDecode ([math]::Round(1e9 / $d)) -MaxPartitionDecode ([math]::Round(1e9 / $d)) -OptimalPartitionDecode ([math]::Round(1e9 / $d)) `
            -MinPartitionCompute ([math]::Round(1e9 / $d)) -MaxPartitionCompute ([math]::Round(1e9 / $d)) -OptimalPartitionCompute ([math]::Round(1e9 / $d))
        "GPU-P attached to $VMName ($Percent%)"
    }
    'Detach' {
        Get-VMGpuPartitionAdapter -VMName $VMName -ErrorAction SilentlyContinue | Remove-VMGpuPartitionAdapter
        "GPU-P detached from $VMName"
    }
}
