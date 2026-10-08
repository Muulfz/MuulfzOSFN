$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

$7z = @((Get-Command 7z -ErrorAction SilentlyContinue).Source, 'C:\Program Files\7-Zip\7z.exe') |
    Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $7z) { throw '7-Zip not found. Install: winget install 7zip.7zip' }

# 1. Compose (inline !include) + tag-filter to the AME artifact
& uv run --with pyyaml python tools/compose.py --input playbook/main-fortnite.yml --output dist/main-flat-fortnite.yml
if ($LASTEXITCODE) { throw "compose failed ($LASTEXITCODE)" }
& uv run --with pyyaml python tools/build.py --input dist/main-flat-fortnite.yml --output dist/MuulfzOSFN-fortnite.yml `
    --target personal --mode competitive --gamepass strip
if ($LASTEXITCODE) { throw "build failed ($LASTEXITCODE)" }

# 2. Stage AME layout: playbook.conf at root, Configuration/main.yml, Images/, Executables/
$pack = 'dist/pack-src-fortnite'
if (Test-Path $pack) { Remove-Item -Recurse -Force $pack }
New-Item -ItemType Directory -Path "$pack/Configuration" | Out-Null
Copy-Item playbook/playbook-fortnite.conf "$pack/playbook.conf"
Copy-Item dist/MuulfzOSFN-fortnite.yml "$pack/Configuration/main.yml"
if (Test-Path 'playbook/Images') { Copy-Item -Recurse 'playbook/Images' "$pack/Images" }
if (Test-Path 'playbook/Executables') { Copy-Item -Recurse 'playbook/Executables' "$pack/Executables" }   # wallpaper.jpg (exeDir actions)

# 3. Pack (AME password: malte)
$apbx = (Resolve-Path 'dist').Path + '\MuulfzOSFN-fortnite.apbx'
if (Test-Path $apbx) { Remove-Item $apbx -Force }
Push-Location $pack
try { & $7z a -tzip -p"malte" $apbx '*' | Out-Null } finally { Pop-Location }
Remove-Item -Recurse -Force $pack

Write-Host "apbx: $apbx"
Write-Host ("sha:  {0}" -f (Get-FileHash -Algorithm SHA256 $apbx).Hash)
