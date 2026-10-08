@echo off
:: Undo setup-host.cmd: optionally deletes the MuulfzOSFN test VMs, removes you from
:: Hyper-V Administrators and turns Hyper-V off. Double-click; asks for admin.
net session >nul 2>&1 || (powershell -NoProfile -Command "Start-Process '%~f0' -Verb RunAs" & exit /b)

choice /m "Delete the MuulfzOSFN test VMs and their disks (C:\VMs, ~200 GB)"
if errorlevel 2 goto keep
echo Deleting test VMs...
powershell -NoProfile -Command "Get-VM MuulfzOSFN-* -ErrorAction SilentlyContinue | Stop-VM -TurnOff -Force -ErrorAction SilentlyContinue; Get-VM MuulfzOSFN-* -ErrorAction SilentlyContinue | Remove-VM -Force; Remove-Item C:\VMs -Recurse -Force -ErrorAction SilentlyContinue"
:keep

echo.
echo [1/2] Removing %USERNAME% from Hyper-V Administrators...
powershell -NoProfile -Command "Remove-LocalGroupMember -SID S-1-5-32-578 -Member '%USERNAME%' -ErrorAction SilentlyContinue"

echo.
echo [2/2] Disabling Hyper-V...
dism /online /disable-feature /featurename:Microsoft-Hyper-V-All /norestart

echo.
echo Hyper-V is removed after a reboot.
choice /m "Reboot now"
if errorlevel 2 exit /b
shutdown /r /t 5
