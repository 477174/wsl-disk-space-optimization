<#
.SYNOPSIS
    Registers the WSL Disk Optimizer watcher as a Windows Task Scheduler task.

.DESCRIPTION
    This script creates a scheduled task that:
    - Starts the TCP watcher at system boot (with 10-second delay)
    - Runs under SYSTEM principal with Highest privileges
    - Auto-restarts on failure (every 1 minute, up to 999 times)
    - Runs indefinitely without execution time limits
    - Ignores new task instances if one is already running

.NOTES
    Requires Administrator privileges to register scheduled tasks.
#>

# Self-elevate if not running as Administrator (triggers UAC prompt)
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -Verb RunAs -Wait
    exit $LASTEXITCODE
}

# Task configuration
$taskName = "WSL-Disk-Optimizer"
$scriptPath = Join-Path -Path $PSScriptRoot -ChildPath "wsl-compact-watcher.ps1"

# Verify the watcher script exists
if (-not (Test-Path -Path $scriptPath)) {
    Write-Error "Watcher script not found at: $scriptPath"
    exit 1
}

Write-Host "Registering scheduled task: $taskName" -ForegroundColor Cyan
Write-Host "Watcher script: $scriptPath" -ForegroundColor Gray

# Create the task action
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""

# Create the startup trigger with 10-second delay
$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = 'PT10S'

# Create task settings
$settings = New-ScheduledTaskSettingsSet `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -RestartCount 999 `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable

# Create the principal (SYSTEM account with Highest privileges)
$principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

# Register the task (idempotent with -Force)
try {
    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Force `
        -ErrorAction Stop | Out-Null
    
    Write-Host "[OK] Task registered successfully" -ForegroundColor Green
}
catch {
    Write-Error "Failed to register task: $_"
    exit 1
}

# Start the task immediately
try {
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
    Write-Host "[OK] Task started successfully" -ForegroundColor Green
}
catch {
    Write-Error "Failed to start task: $_"
    exit 1
}

# Display verification information
Write-Host "`nTask Information:" -ForegroundColor Cyan
Get-ScheduledTaskInfo -TaskName $taskName | Format-List

Write-Host "`nTask Details:" -ForegroundColor Cyan
Get-ScheduledTask -TaskName $taskName | Format-List TaskName, State, @{Name="LastRunTime"; Expression={$_.LastRunTime}}, @{Name="NextRunTime"; Expression={$_.NextRunTime}}

Write-Host "`n[OK] Setup complete. The watcher will start at next system boot." -ForegroundColor Green
