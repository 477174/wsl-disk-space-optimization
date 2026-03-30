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

  $wslRoot = Join-Path $localAppData 'wsl'
  if (Test-Path $wslRoot) {
    Get-ChildItem -Path $wslRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $vhdx = Join-Path $_.FullName "ext4.vhdx"
      if (Test-Path $vhdx) { $vhdxPaths += $vhdx }
    }
  }

  $packagesRoot = Join-Path $localAppData 'Packages'
  if (Test-Path $packagesRoot) {
    Get-ChildItem -Path $packagesRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $vhdx = Join-Path $_.FullName "LocalState\ext4.vhdx"
      if (Test-Path $vhdx) { $vhdxPaths += $vhdx }
    }
  }

  foreach ($dockerSub in @('Docker\wsl\data', 'Docker\wsl\distro')) {
    $vhdx = Join-Path $localAppData "$dockerSub\ext4.vhdx"
    if (Test-Path $vhdx) { $vhdxPaths += $vhdx }
  }
}

if ($vhdxPaths.Count -eq 0) {
  Log "WARNING: No VHDX files found. Nothing to compact."
  exit 0
}

Log "Found $($vhdxPaths.Count) VHDX file(s):"
foreach ($p in $vhdxPaths) { Log "  $p" }

$hasOptimizeVHD = [bool](Get-Command Optimize-VHD -ErrorAction SilentlyContinue)

foreach ($vhdx in $vhdxPaths) {
  $sizeBefore = (Get-Item $vhdx).Length / 1GB
  Log "Compacting: $vhdx (current size: $([math]::Round($sizeBefore, 2)) GB)"
  if (-not $DryRun) {
    if ($hasOptimizeVHD) {
      Log "  Using Optimize-VHD"
      Optimize-VHD -Path $vhdx -Mode Full
    } else {
      Log "  Using diskpart"
      $tmpFile = [System.IO.Path]::GetTempFileName()
      @("select vdisk file=`"$vhdx`"", "compact vdisk") | Set-Content -Path $tmpFile -Encoding ASCII
      $output = & diskpart /s $tmpFile 2>&1
      Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
      $output | ForEach-Object { Log "  diskpart: $_" }
    }
    $sizeAfter = (Get-Item $vhdx).Length / 1GB
    $saved = $sizeBefore - $sizeAfter
    Log "  Compacted: $([math]::Round($sizeBefore, 2)) GB -> $([math]::Round($sizeAfter, 2)) GB (saved $([math]::Round($saved, 2)) GB)"
  } else {
    Log "  [DRY RUN] Would compact $vhdx ($([math]::Round($sizeBefore, 2)) GB)"
  }
}
Log "=== Compaction complete ==="
