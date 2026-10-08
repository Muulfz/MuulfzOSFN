@echo off
:: One-time host prep for the MuulfzOSFN test VM. Double-click; asks for admin.
::   1. enables Hyper-V   2. adds you to Hyper-V Administrators (so new-test-vm.ps1
::   runs without elevation)   3. opens the official 26H2 ISO download page
net session >nul 2>&1 || (powershell -NoProfile -Command "Start-Process '%~f0' -Verb RunAs" & exit /b)

echo [1/3] Enabling Hyper-V...
dism /online /enable-feature /featurename:Microsoft-Hyper-V-All /all /norestart

echo.
echo [2/3] Adding %USERNAME% to Hyper-V Administrators (SID S-1-5-32-578)...
powershell -NoProfile -Command "Add-LocalGroupMember -SID S-1-5-32-578 -Member '%USERNAME%' -ErrorAction SilentlyContinue; Get-LocalGroupMember -SID S-1-5-32-578 | Format-Table Name, PrincipalSource"

echo.
echo [3/3] Opening the Windows 11 ISO page: pick "Windows 11 (multi-edition ISO for x64 devices)".
start "" https://www.microsoft.com/software-download/windows11

echo.
echo Hyper-V needs a reboot. If the ISO is still downloading, answer N and reboot later.
choice /m "Reboot now"
if errorlevel 2 exit /b
shutdown /r /t 5
