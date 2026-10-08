# Release kit: builds the apbx, then dist/kit/ with the versioned apbx, wallpaper,
# pt-PT read-me + tutorial and SHA256SUMS, zipped as dist/MuulfzOSFN-<version>-kit.zip.
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

Tutorial completo: TUTORIAL-pt-PT.md (abre com o Bloco de Notas ou no GitHub).

1. Transfere o AME Wizard: https://ameliorated.io
2. Windows atual: arrasta MuulfzOSFN-$ver.apbx para o AME e segue o assistente.
   Le antes a secao "Riscos de aplicar no PC atual" do tutorial.
3. Instalacao de raiz (recomendado): grava a ISO oficial do Windows 11 numa pen USB com o
   Rufus (sem conta Microsoft, sem BitLocker), instala e cria a tua conta. Depois abre o AME
   e escolhe o .apbx.
4. No fim, abre "Fortnite - MuulfzOSFN.txt" na area de trabalho.

Confirma os ficheiros com SHA256SUMS.txt (PowerShell: Get-FileHash <ficheiro>).
"@ | Set-Content "$kit/LEIA-ME.txt" -Encoding utf8
Copy-Item docs/TUTORIAL-pt-PT.md "$kit/TUTORIAL-pt-PT.md"
Get-ChildItem $kit -File | Where-Object Name -ne 'SHA256SUMS.txt' | ForEach-Object {
    '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name } | Set-Content "$kit/SHA256SUMS.txt" -Encoding ascii
$zip = "dist/MuulfzOSFN-$ver-kit.zip"
Compress-Archive -Path "$kit/*" -DestinationPath $zip -Force
Write-Host "kit: $zip"
Get-Content "$kit/SHA256SUMS.txt"
