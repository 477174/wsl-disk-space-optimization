#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Compacts WSL VHDX files to reclaim disk space on Windows.
.PARAMETER DryRun
  If set, logs what WOULD happen without executing destructive actions.
#>
param([switch]$DryRun)

$LogFile = "$PSScriptRoot\logs\wsl-compact.log"
New-Item -ItemType Directory -Path "$PSScriptRoot\logs" -Force | Out-Null

function Log($msg) {
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $entry = "[$ts] $msg"
  Write-Host $entry
  Add-Content -Path $LogFile -Value $entry
}

Log "=== WSL VHDX Compaction $(if ($DryRun) { '(DRY RUN)' }) ==="

Log "Running fstrim inside WSL..."
if (-not $DryRun) {
  wsl -u root -e fstrim -av 2>&1 | ForEach-Object { Log "  fstrim: $_" }
} else {
  Log "  [DRY RUN] Would run: wsl -u root -e fstrim -av"
}

Log "Shutting down WSL..."
if (-not $DryRun) {
  wsl --shutdown
  Start-Sleep -Seconds 5
  $maxWait = 30; $waited = 0
  while ($waited -lt $maxWait) {
    $running = wsl -l -v 2>&1 | Select-String "Running"
    if (-not $running) { break }
    Start-Sleep -Seconds 2; $waited += 2
  }
  if ($waited -ge $maxWait) {
    Log "ERROR: WSL did not shutdown within ${maxWait}s. Aborting."
    exit 1
  }
  Log "WSL shutdown confirmed."
} else {
  Log "  [DRY RUN] Would run: wsl --shutdown"
}

$vhdxPaths = @()
$packages = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "Ubuntu|Debian|SUSE|Kali|Fedora|Canonical" }
foreach ($pkg in $packages) {
  $vhdx = Join-Path $pkg.FullName "LocalState\ext4.vhdx"
  if (Test-Path $vhdx) { $vhdxPaths += $vhdx }
}
$dockerVhdx = "$env:LOCALAPPDATA\Docker\wsl\data\ext4.vhdx"
if (Test-Path $dockerVhdx) { $vhdxPaths += $dockerVhdx }
$dockerDistroVhdx = "$env:LOCALAPPDATA\Docker\wsl\distro\ext4.vhdx"
if (Test-Path $dockerDistroVhdx) { $vhdxPaths += $dockerDistroVhdx }

if ($vhdxPaths.Count -eq 0) {
  Log "WARNING: No VHDX files found. Nothing to compact."
  exit 0
}

foreach ($vhdx in $vhdxPaths) {
  $sizeBefore = (Get-Item $vhdx).Length / 1GB
  Log "Compacting: $vhdx (current size: $([math]::Round($sizeBefore, 2)) GB)"
  if (-not $DryRun) {
    if (Get-Command Optimize-VHD -ErrorAction SilentlyContinue) {
      Optimize-VHD -Path $vhdx -Mode Full
    } else {
      $diskpartScript = "select vdisk file=`"$vhdx`"`ncompact vdisk`ndetach vdisk"
      $diskpartScript | diskpart
    }
    $sizeAfter = (Get-Item $vhdx).Length / 1GB
    $saved = $sizeBefore - $sizeAfter
    Log "  Compacted: $([math]::Round($sizeBefore, 2)) GB -> $([math]::Round($sizeAfter, 2)) GB (saved $([math]::Round($saved, 2)) GB)"
  } else {
    Log "  [DRY RUN] Would compact $vhdx ($([math]::Round($sizeBefore, 2)) GB)"
  }
}
Log "=== Compaction complete ==="
