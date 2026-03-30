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

# Verify WSL is not running (vmmem absent = WSL VM is down)
$vmmem = Get-Process -Name vmmem -ErrorAction SilentlyContinue
if ($vmmem) {
  Log "ERROR: vmmem is running — WSL is still active. Cannot compact while VHDX is in use."
  exit 1
}

$vhdxPaths = @()
$userDirs = Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') }

foreach ($userDir in $userDirs) {
  $localAppData = Join-Path $userDir.FullName 'AppData\Local'

  $packages = Get-ChildItem (Join-Path $localAppData 'Packages') -Directory -ErrorAction SilentlyContinue
  foreach ($pkg in $packages) {
    $vhdx = Join-Path $pkg.FullName "LocalState\ext4.vhdx"
    if (Test-Path $vhdx) { $vhdxPaths += $vhdx }
  }

  $dockerVhdx = Join-Path $localAppData 'Docker\wsl\data\ext4.vhdx'
  if (Test-Path $dockerVhdx) { $vhdxPaths += $dockerVhdx }
  $dockerDistroVhdx = Join-Path $localAppData 'Docker\wsl\distro\ext4.vhdx'
  if (Test-Path $dockerDistroVhdx) { $vhdxPaths += $dockerDistroVhdx }
}

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
