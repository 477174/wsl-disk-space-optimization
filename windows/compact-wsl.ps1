param([switch]$DryRun)

$LogFile = "$PSScriptRoot\logs\wsl-compact.log"
New-Item -ItemType Directory -Path "$PSScriptRoot\logs" -Force | Out-Null

function Log($msg) {
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $entry = "[$ts] $msg"
  Write-Host $entry
  Add-Content -Path $LogFile -Value $entry
}

$runMode = if ($DryRun) { ' (DRY RUN)' } else { '' }
Log "=== WSL VHDX Compaction$runMode ==="

$vmmem = Get-Process -Name vmmem -ErrorAction SilentlyContinue
if ($vmmem) {
  Log "ERROR: vmmem is running. Cannot compact while VHDX is in use."
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

Log ("Found {0} VHDX file(s):" -f $vhdxPaths.Count)
foreach ($p in $vhdxPaths) { Log "  $p" }

$hasOptimizeVHD = [bool](Get-Command Optimize-VHD -ErrorAction SilentlyContinue)

foreach ($vhdx in $vhdxPaths) {
  $sizeBefore = [math]::Round((Get-Item $vhdx).Length / 1GB, 2)
  Log ("Compacting: {0} - current size: {1} GB" -f $vhdx, $sizeBefore)
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
    $sizeAfter = [math]::Round((Get-Item $vhdx).Length / 1GB, 2)
    $saved = [math]::Round($sizeBefore - $sizeAfter, 2)
    Log ("  Result: {0} GB -> {1} GB, saved {2} GB" -f $sizeBefore, $sizeAfter, $saved)
  } else {
    Log ("  [DRY RUN] Would compact {0} - {1} GB" -f $vhdx, $sizeBefore)
  }
}
Log "=== Compaction complete ==="
