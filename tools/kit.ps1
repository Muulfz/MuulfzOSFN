# Release kit: builds the apbx, then dist/kit/ with the versioned apbx, wallpaper,
# PT-BR read-me and SHA256SUMS, zipped as dist/MuulfzOSFN-<version>-kit.zip.
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
& (Join-Path $PSScriptRoot 'build.ps1')

$ver = ([xml](Get-Content playbook/playbook-fortnite.conf -Raw)).Playbook.Version
$kit = 'dist/kit'
if (Test-Path $kit) { Remove-Item -Recurse -Force $kit }
New-Item -ItemType Directory $kit | Out-Null
Copy-Item dist/MuulfzOSFN-fortnite.apbx "$kit/MuulfzOSFN-$ver.apbx"
Copy-Item playbook/Executables/wallpaper.jpg "$kit/MuulfzOS-wallpaper-4k.jpg"
@"
MuulfzOS Fortnite Edition $ver
https://github.com/Muulfz/MuulfzOSFN

1. Baixe o AME Wizard: https://ameliorated.io
2. Windows atual: arraste MuulfzOSFN-$ver.apbx para o AME e siga o assistente.
3. Instalacao limpa: no AME, arraste a ISO oficial do Windows 11 (microsoft.com) e depois
   o .apbx, escolha modificar a ISO e crie a sua conta (nome e senha) quando o AME pedir.
   Grave a ISO num pen drive (Rufus ou o proprio AME) e instale.
4. Depois, abra "Fortnite - MuulfzOSFN.txt" na area de trabalho.

Confira os arquivos com SHA256SUMS.txt (PowerShell: Get-FileHash <arquivo>).
"@ | Set-Content "$kit/LEIA-ME.txt" -Encoding utf8
Get-ChildItem $kit -File | Where-Object Name -ne 'SHA256SUMS.txt' | ForEach-Object {
    '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name } | Set-Content "$kit/SHA256SUMS.txt" -Encoding ascii
$zip = "dist/MuulfzOSFN-$ver-kit.zip"
Compress-Archive -Path "$kit/*" -DestinationPath $zip -Force
Write-Host "kit: $zip"
Get-Content "$kit/SHA256SUMS.txt"
