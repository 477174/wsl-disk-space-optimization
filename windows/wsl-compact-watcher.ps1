param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Port = 19999
if ($env:WSL_HEARTBEAT_PORT) {
  $parsedPort = 0
  if ([int]::TryParse($env:WSL_HEARTBEAT_PORT, [ref]$parsedPort) -and $parsedPort -gt 0 -and $parsedPort -le 65535) {
    $Port = $parsedPort
  }
}

$GracePeriodSeconds = 30
$LogDirectory = Join-Path $PSScriptRoot 'logs'
$LogFile = Join-Path $LogDirectory 'wsl-watcher.log'

New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null

function Write-Log {
  param([string]$Message)

  $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $entry = "[$timestamp] $Message"
  Write-Host $entry
  Add-Content -Path $LogFile -Value $entry
}

function Set-TcpKeepAlive {
  param([System.Net.Sockets.Socket]$Socket)

  $keepAlive = [byte[]]::new(12)
  [BitConverter]::GetBytes([int]1).CopyTo($keepAlive, 0)
  [BitConverter]::GetBytes([int]5000).CopyTo($keepAlive, 4)
  [BitConverter]::GetBytes([int]1000).CopyTo($keepAlive, 8)
  $Socket.IOControl([System.Net.Sockets.IOControlCode]::KeepAliveValues, $keepAlive, $null) | Out-Null
}

function Test-VmmemRunning {
  return [bool](Get-Process -Name vmmem -ErrorAction SilentlyContinue)
}

function Get-VhdxPaths {
  if ($env:WSL_VHDX_PATH) {
    $parts = $env:WSL_VHDX_PATH -split '[,;]'
    return @($parts | ForEach-Object { $_.Trim() } | Where-Object { $_ -and (Test-Path $_) })
  }

  $paths = @()
  $packageRoot = Join-Path $env:LOCALAPPDATA 'Packages'
  if (Test-Path $packageRoot) {
    $packages = Get-ChildItem -Path $packageRoot -Directory -ErrorAction SilentlyContinue
    foreach ($pkg in $packages) {
      $candidate = Join-Path $pkg.FullName 'LocalState\ext4.vhdx'
      if (Test-Path $candidate) {
        $paths += $candidate
      }
    }
  }

  $dockerDataVhdx = Join-Path $env:LOCALAPPDATA 'Docker\wsl\data\ext4.vhdx'
  if (Test-Path $dockerDataVhdx) {
    $paths += $dockerDataVhdx
  }

  $dockerDistroVhdx = Join-Path $env:LOCALAPPDATA 'Docker\wsl\distro\ext4.vhdx'
  if (Test-Path $dockerDistroVhdx) {
    $paths += $dockerDistroVhdx
  }

  return @($paths | Select-Object -Unique)
}

function Test-VhdxLocked($path) {
  try {
    $fs = [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
    $fs.Close(); return $false
  } catch {
    return $true
  }
}

function Test-SafeToCompact {
  if (Test-VmmemRunning) {
    Write-Log 'Safety check failed: vmmem process is still running.'
    return $false
  }

  $vhdxPaths = @(Get-VhdxPaths)
  if ($vhdxPaths.Count -eq 0) {
    Write-Log 'Safety check failed: no VHDX paths found.'
    return $false
  }

  foreach ($vhdx in $vhdxPaths) {
    if (Test-VhdxLocked $vhdx) {
      Write-Log "Safety check failed: VHDX is locked: $vhdx"
      return $false
    }
  }

  Write-Log 'Safety check passed: no vmmem, no VHDX locks.'
  return $true
}

function Wait-ForVmmemExit {
  param([int]$TimeoutSeconds = 120)

  $elapsed = 0
  while ($elapsed -lt $TimeoutSeconds) {
    if (-not (Test-VmmemRunning)) {
      return $true
    }
    Start-Sleep -Seconds 2
    $elapsed += 2
  }

  return $false
}

function Invoke-DisconnectSequence {
  param([string]$DisconnectReason)

  Write-Log "State=DISCONNECTED reason=$DisconnectReason"
  Write-Log "Entering ${GracePeriodSeconds}s grace period before compaction checks."

  $elapsed = 0
  while ($elapsed -lt $GracePeriodSeconds) {
    Start-Sleep -Seconds 5
    $elapsed += 5

    if ($listener.Pending()) {
      Write-Log 'Heartbeat client reconnected during grace period, cancelling compaction.'
      return
    }
  }

  Write-Log 'Grace period ended. Waiting for vmmem to exit...'
  if (-not (Wait-ForVmmemExit -TimeoutSeconds 120)) {
    Write-Log 'ERROR: vmmem still running after 120s. WSL is still alive. Skipping compaction.'
    return
  }

  if (-not (Test-SafeToCompact)) {
    Write-Log 'ERROR: Safety check failed. Skipping compaction.'
    return
  }

  Write-Log 'State=COMPACTING invoking compact-wsl.ps1'
  try {
    & "$PSScriptRoot\compact-wsl.ps1" 2>&1 | ForEach-Object { Write-Log "  compact: $_" }
    Write-Log 'Compaction completed.'
  } catch {
    Write-Log "ERROR: compact-wsl.ps1 failed: $($_.Exception.Message)"
  }
}

$listener = $null

try {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
  $listener.Start()
  Write-Log "WSL compact watcher started on 127.0.0.1:$Port"

  while ($true) {
    $state = 'LISTENING'
    $client = $null
    $disconnectReason = $null

    try {
      Write-Log 'State=LISTENING waiting for heartbeat client connection.'
      $client = $listener.AcceptTcpClient()
      $state = 'CONNECTED'
      Write-Log 'State=CONNECTED heartbeat client connected.'

      $socket = $client.Client
      Set-TcpKeepAlive -Socket $socket

      while ($true) {
        if ($socket.Poll(1000000, [System.Net.Sockets.SelectMode]::SelectRead) -and $socket.Available -eq 0) {
          $disconnectReason = 'clean FIN (socket poll/readable + available=0)'
          break
        }

        Start-Sleep -Milliseconds 500
      }

      if ($disconnectReason) {
        Invoke-DisconnectSequence -DisconnectReason $disconnectReason
      }
    } catch {
      Write-Log "ERROR: Main loop exception in state=${state}: $($_.Exception.Message)"
    } finally {
      if ($client) { $client.Close(); $client.Dispose() }
      Write-Log 'State=LISTENING returning to listen for the next connection.'
    }
  }
} catch {
  Write-Log "ERROR: Failed to initialize watcher: $($_.Exception.Message)"
  throw
} finally {
  if ($listener) {
    $listener.Stop()
  }
}
