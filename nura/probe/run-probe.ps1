# run-probe.ps1 — push + run + pull the feasibility probe from the connected phone.
# Requires: adb, USB debugging enabled, and the phone rooted (Magisk etc.).
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
New-Item -ItemType Directory -Force -Path "$here\results" | Out-Null

# 1. wait for device
$dev = adb devices | Select-String "device$"
if (-not $dev) { Write-Host "No device. Plug the phone in, enable USB debugging, accept the prompt." -ForegroundColor Yellow; exit 1 }

# 2. push probe
adb push "$here\probe-nura.sh" /data/local/tmp/probe-nura.sh | Out-Host

# 3. run as root
adb shell su 0 sh /data/local/tmp/probe-nura.sh /data/local/tmp/nura_probe_report.txt

# 4. pull back
adb pull /data/local/tmp/nura_probe_report.txt "$here\results\nura_probe_$stamp.txt" | Out-Host

Write-Host ""
Write-Host "Report:" -ForegroundColor Green
Write-Host "  $here\results\nura_probe_$stamp.txt"
