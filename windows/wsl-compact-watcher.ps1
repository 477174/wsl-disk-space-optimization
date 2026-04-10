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

$GracePeriodSeconds = 0
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

function Test-WslVmRunning {
  return [bool](Get-Process -Name vmmem,vmwp -ErrorAction SilentlyContinue)
}

function Get-VhdxPaths {
  if ($env:WSL_VHDX_PATH) {
    $parts = $env:WSL_VHDX_PATH -split '[,;]'
    return @($parts | ForEach-Object { $_.Trim() } | Where-Object { $_ -and (Test-Path $_) })
  }

  $paths = @()
  $userDirs = Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') }

  foreach ($userDir in $userDirs) {
    $localAppData = Join-Path $userDir.FullName 'AppData\Local'

    $wslRoot = Join-Path $localAppData 'wsl'
    if (Test-Path $wslRoot) {
      Get-ChildItem -Path $wslRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $candidate = Join-Path $_.FullName 'ext4.vhdx'
        if (Test-Path $candidate) { $paths += $candidate }
      }
    }

    $packageRoot = Join-Path $localAppData 'Packages'
    if (Test-Path $packageRoot) {
      Get-ChildItem -Path $packageRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $candidate = Join-Path $_.FullName 'LocalState\ext4.vhdx'
        if (Test-Path $candidate) { $paths += $candidate }
      }
    }

    foreach ($dockerSub in @('Docker\wsl\data', 'Docker\wsl\distro')) {
      $candidate = Join-Path $localAppData "$dockerSub\ext4.vhdx"
      if (Test-Path $candidate) { $paths += $candidate }
    }
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
  if (Test-WslVmRunning) {
    Write-Log 'Safety check failed: WSL VM processes still running.'
    return $false
  }

  $vhdxPaths = @(Get-VhdxPaths)
  Write-Log "Found $($vhdxPaths.Count) VHDX file(s): $($vhdxPaths -join ', ')"
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

function Wait-ForShutdown {
  param([int]$TimeoutSeconds = 120)

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $vmmemDone = $false
  $vhdxDone = $false

  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    if ($listener.Pending()) {
      Write-Log 'WSL reconnected during shutdown wait, cancelling compaction.'
      return 'reconnected'
    }

    if (-not $vmmemDone) {
      if (-not (Test-WslVmRunning)) {
        Write-Log 'WSL VM processes (vmmem/vmwp) have exited.'
        $vmmemDone = $true
      }
    }

    if ($vmmemDone -and -not $vhdxDone) {
      $vhdxPaths = @(Get-VhdxPaths)
      if ($vhdxPaths.Count -eq 0) {
        Write-Log 'No VHDX files found.'
        return 'no-vhdx'
      }
      $allUnlocked = $true
      foreach ($vhdx in $vhdxPaths) {
        if (Test-VhdxLocked $vhdx) {
          $allUnlocked = $false
          break
        }
      }
      if ($allUnlocked) {
        Write-Log 'All VHDX files unlocked.'
        $vhdxDone = $true
      }
    }

    if ($vmmemDone -and $vhdxDone) {
      return 'ready'
    }

    Start-Sleep -Seconds 2
  }

  $pending = @()
  if (-not $vmmemDone) { $pending += 'WSL VM still running (vmmem/vmwp)' }
  if (-not $vhdxDone) { $pending += 'VHDX still locked' }
  Write-Log "Timeout after ${TimeoutSeconds}s: $($pending -join ', ')"
  return 'timeout'
}

function Invoke-DisconnectSequence {
  param([string]$DisconnectReason)

  Write-Log "State=DISCONNECTED reason=$DisconnectReason"
  Write-Log 'Waiting for WSL to fully shut down (vmmem exit + VHDX unlock)...'

  $result = Wait-ForShutdown -TimeoutSeconds 120

  if ($result -ne 'ready') {
    Write-Log "Shutdown wait result: $result. Skipping compaction."
    return
  }

  if (-not (Test-SafeToCompact)) {
    Write-Log 'ERROR: Final safety check failed. Skipping compaction.'
    return
  }

  Write-Log 'State=COMPACTING invoking compact-wsl.ps1'
  try {
    $compactScript = Join-Path $PSScriptRoot 'compact-wsl.ps1'
    $taskName = 'WSL-Disk-Optimizer-Compact'
    $loggedOnUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName

    if ($loggedOnUser) {
      Write-Log "Launching interactive compaction as $loggedOnUser"
      $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$compactScript`""
      $taskPrincipal = New-ScheduledTaskPrincipal -UserId $loggedOnUser -LogonType Interactive -RunLevel Highest
      Register-ScheduledTask -TaskName $taskName -Action $taskAction -Principal $taskPrincipal -Force | Out-Null
      Start-ScheduledTask -TaskName $taskName

      while ((Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State -eq 'Running') {
        Start-Sleep -Seconds 2
      }

      Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    } else {
      Write-Log 'No interactive user session, running headless'
      & $compactScript 2>&1 | ForEach-Object { Write-Log "  compact: $_" }
    }

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
