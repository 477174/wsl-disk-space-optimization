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

$HeartbeatIntervalSeconds = 5
$HeartbeatTimeoutMilliseconds = 3000
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

function Get-RunningWslDistros {
  try {
    $output = & wsl --list --running 2>&1
    if (-not $output) {
      return @()
    }

    $lines = @($output | ForEach-Object { $_.ToString().Trim() })
    if ($lines -match 'There are no running distributions') {
      return @()
    }

    return @(
      $lines | Where-Object {
        $_ -and
        $_ -notmatch '^Windows Subsystem for Linux' -and
        $_ -notmatch '^The following is a list of running distributions' -and
        $_ -notmatch '^NAME\s+STATE\s+VERSION$'
      } | ForEach-Object { $_.TrimStart('*').Trim() }
    )
  } catch {
    Write-Log "ERROR: Failed to query running WSL distros: $($_.Exception.Message)"
    return @()
  }
}

function Test-WslRunning {
  return (Get-RunningWslDistros).Count -gt 0
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

function Test-TripleCheck {
  $runningDistros = Get-RunningWslDistros
  if ($runningDistros.Count -gt 0) {
    Write-Log "Triple-check failed: running distros detected: $($runningDistros -join ', ')"
    return $false
  }

  $vmmem = Get-Process -Name vmmem -ErrorAction SilentlyContinue
  if ($vmmem) {
    Write-Log 'Triple-check failed: vmmem process is still running.'
    return $false
  }

  $vhdxPaths = Get-VhdxPaths
  if ($vhdxPaths.Count -eq 0) {
    Write-Log 'Triple-check failed: no VHDX paths found for lock test.'
    return $false
  }

  foreach ($vhdx in $vhdxPaths) {
    if (Test-VhdxLocked $vhdx) {
      Write-Log "Triple-check failed: VHDX is locked: $vhdx"
      return $false
    }
  }

  Write-Log 'Triple-check passed: no running distros, no vmmem, no VHDX locks.'
  return $true
}

function Wait-ForWslShutdown {
  param([int]$TimeoutSeconds = 60)

  $elapsed = 0
  while ($elapsed -lt $TimeoutSeconds) {
    $runningDistros = Get-RunningWslDistros
    $vmmem = Get-Process -Name vmmem -ErrorAction SilentlyContinue
    if ($runningDistros.Count -eq 0 -and -not $vmmem) {
      return $true
    }

    Start-Sleep -Seconds 2
    $elapsed += 2
  }

  return $false
}

function Read-LineWithTimeout {
  param(
    [System.IO.StreamReader]$Reader,
    [int]$TimeoutMilliseconds
  )

  $task = $Reader.ReadLineAsync()
  if ($task.Wait($TimeoutMilliseconds)) {
    return $task.Result
  }

  return $null
}

function Invoke-DisconnectSequence {
  param([string]$DisconnectReason)

  Write-Log "State=DISCONNECTED reason=$DisconnectReason"
  Write-Log "Entering ${GracePeriodSeconds}s grace period before compaction checks."

  $elapsed = 0
  while ($elapsed -lt $GracePeriodSeconds) {
    Start-Sleep -Seconds 5
    $elapsed += 5

    if (Test-WslRunning) {
      Write-Log 'WSL restarted, cancelling compaction.'
      return
    }
  }

  try {
    Write-Log 'Running fallback fstrim: wsl -u root -e fstrim -av'
    & wsl -u root -e fstrim -av 2>&1 | ForEach-Object { Write-Log "  fstrim: $_" }
  } catch {
    Write-Log "ERROR: fstrim command failed: $($_.Exception.Message)"
  }

  try {
    Write-Log 'Running wsl --shutdown'
    & wsl --shutdown | Out-Null
  } catch {
    Write-Log "ERROR: wsl --shutdown failed: $($_.Exception.Message)"
  }

  if (-not (Wait-ForWslShutdown -TimeoutSeconds 60)) {
    Write-Log 'ERROR: WSL did not fully shutdown within 60 seconds. Skipping compaction.'
    return
  }

  if (-not (Test-TripleCheck)) {
    Write-Log 'ERROR: Triple-check failed. Skipping compaction.'
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
    $stream = $null
    $reader = $null
    $writer = $null
    $disconnectReason = $null

    try {
      Write-Log 'State=LISTENING waiting for heartbeat client connection.'
      $client = $listener.AcceptTcpClient()
      $state = 'CONNECTED'
      Write-Log 'State=CONNECTED heartbeat client connected.'

      $socket = $client.Client
      Set-TcpKeepAlive -Socket $socket

      $stream = $client.GetStream()
      $reader = [System.IO.StreamReader]::new($stream)
      $writer = [System.IO.StreamWriter]::new($stream)
      $writer.NewLine = "`n"
      $writer.AutoFlush = $true

      $nextHeartbeat = Get-Date
      while ($true) {
        if ($socket.Poll(1000, [System.Net.Sockets.SelectMode]::SelectRead) -and $socket.Available -eq 0) {
          $disconnectReason = 'clean FIN (socket poll/readable + available=0)'
          break
        }

        if ((Get-Date) -ge $nextHeartbeat) {
          try {
            $writer.WriteLine('PING')
          } catch {
            $disconnectReason = "write failure while sending PING: $($_.Exception.Message)"
            break
          }

          $pong = Read-LineWithTimeout -Reader $reader -TimeoutMilliseconds $HeartbeatTimeoutMilliseconds
          if ([string]::IsNullOrWhiteSpace($pong) -or $pong.Trim() -ne 'PONG') {
            $disconnectReason = 'heartbeat timeout or invalid heartbeat response'
            break
          }

          $nextHeartbeat = (Get-Date).AddSeconds($HeartbeatIntervalSeconds)
        }

        Start-Sleep -Milliseconds 200
      }

      if ($disconnectReason) {
        Invoke-DisconnectSequence -DisconnectReason $disconnectReason
      }
    } catch {
      Write-Log "ERROR: Main loop exception in state=$state: $($_.Exception.Message)"
    } finally {
      if ($writer) { $writer.Dispose() }
      if ($reader) { $reader.Dispose() }
      if ($stream) { $stream.Dispose() }
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
