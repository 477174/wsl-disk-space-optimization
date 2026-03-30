# WSL Disk Space Optimization

Automated disk space reclamation for WSL2 -- event-driven VHDX compaction, Docker garbage collection, and system maintenance.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## What It Does

Four pillars of disk space optimization running as systemd services inside WSL and a scheduled task on Windows:

1. **Docker Cleanup** -- An event-driven garbage collection daemon that prunes unused images whenever containers stop, plus a weekly `docker system prune -af` (volumes are never removed).

2. **WSL Maintenance** -- Periodic memory reclamation (page cache drop + KSM), dev cache cleanup (pip, npm, uv, Playwright, Puppeteer), journal size cap (200M), and zsh history pruning with automatic backups.

3. **VHDX Compaction** -- A TCP watcher on Windows detects when WSL shuts down or crashes and immediately compacts the VHDX. No polling, no periodic scheduling -- purely event-driven via a persistent TCP connection.

4. **Shell Aliases** -- `dcdown` for safe Docker Compose teardown: removes locally-built images and orphan containers while preserving all volumes.

## How It Works

The VHDX compaction pipeline uses a persistent TCP connection between WSL and Windows to detect shutdown events in real time:

```
Windows (Task Scheduler, SYSTEM)         WSL (systemd)
+--------------------------------------+ +-------------------------------+
| wsl-compact-watcher.ps1              | | wsl-heartbeat-client.sh       |
| TcpListener on 127.0.0.1:19999      | | /dev/tcp/ connection + cat    |
|                                      | |                               |
| Socket.Poll detects FIN  <-----------|---  [WSL shuts down / crashes]  |
|                                      | |   ExecStop: fstrim -v /       |
| Safety gate:                         | +-------------------------------+
|   - Wait for vmmem to exit           |
|   - Verify VHDX files not locked     |
|                                      |
| Interactive compaction window         |
|   (or headless if no user session)   |
|   compact-wsl.ps1                    |
|     Optimize-VHD or diskpart         |
+--------------------------------------+
```

**Graceful shutdown**: The heartbeat service runs `fstrim` via its `ExecStop` directive before the TCP connection drops. Windows detects the closed socket, waits for `vmmem` to fully exit, verifies no VHDX file locks remain, then compacts.

**Crash / ungraceful shutdown**: The TCP connection breaks immediately. Windows detects the socket reset via `Socket.Poll`, runs the same safety checks, and compacts. The `fstrim` from `ExecStop` won't have run, but compaction still reclaims space from previously trimmed blocks.

**No polling, no WSL commands**: The watcher never calls `wsl.exe` or `wsl --list --running` -- those commands restart WSL. Detection is purely via TCP socket state and the `vmmem` process.

**Interactive window**: When a user is logged in, compaction runs in a visible PowerShell window (via a temporary scheduled task with `Interactive` logon type) so progress is visible. Falls back to headless when no interactive session is available.

## Prerequisites

- **WSL2 with systemd enabled** -- add `[boot] systemd=true` to `/etc/wsl.conf`
- **Docker Desktop or Docker Engine** (optional) -- only needed for Docker cleanup components
- **bash** (required) -- the heartbeat client uses `/dev/tcp/` which is a bash built-in
- **PowerShell 5.1+** on Windows -- for the watcher and compaction scripts
- **Administrator privileges** on Windows -- required for Task Scheduler registration and VHDX compaction

## Quick Install

```bash
git clone https://github.com/477174/wsl-disk-space-optimization.git
cd wsl-disk-space-optimization
sudo ./install.sh
```

With no flags, `install.sh` installs all components. Docker components are skipped automatically if Docker is not available.

## Modular Install

Select specific component groups with flags:

```bash
# Docker cleanup + WSL maintenance only (no watcher)
sudo ./install.sh --docker --wsl

# Everything except the TCP watcher
sudo ./install.sh --all --no-watcher

# Watcher only, custom port
sudo ./install.sh --watcher --port 20000

# Shell aliases only
sudo ./install.sh --shell

# Custom install directory
sudo ./install.sh --all --install-dir /usr/local/wsl-optimizer
```

Available flags:

| Flag | Description |
|------|-------------|
| `--all` | Install all components (default when no flags given) |
| `--docker` | Docker cleanup components only |
| `--wsl` | WSL maintenance components only |
| `--watcher` | TCP watcher components only |
| `--shell` | Shell aliases only |
| `--no-docker` | Exclude Docker components from `--all` |
| `--no-wsl` | Exclude WSL maintenance from `--all` |
| `--no-watcher` | Exclude watcher from `--all` |
| `--no-shell` | Exclude shell aliases from `--all` |
| `--install-dir DIR` | Installation directory (default: `/opt/wsl-disk-optimizer`) |
| `--port PORT` | Heartbeat TCP port (default: `19999`) |

## What Gets Installed

| Component | Type | Schedule / Trigger | Description |
|-----------|------|--------------------|-------------|
| docker-gc | systemd service | Always running (event-driven) | Prunes unused images on container die/destroy events (60s cooldown) |
| docker-weekly-prune | systemd timer | Sunday 03:00 | `docker system prune -af` -- removes all unused images and containers (not volumes) |
| cache-cleanup | systemd timer | Sunday 03:30 | Cleans pip, npm, uv, Playwright, and Puppeteer caches |
| wsl-mem-cleanup | systemd timer | Every 30 min | Drops page cache and triggers KSM memory deduplication |
| zsh-history-cleanup | systemd timer | Sunday 02:00 | Removes zsh history entries older than 7 days, keeps last 5 backups |
| wsl-heartbeat | systemd service | Always running | TCP connection to Windows watcher; runs `fstrim` on stop |
| WSL-Disk-Optimizer | Windows scheduled task | At system startup | TCP watcher that triggers VHDX compaction on WSL shutdown |
| journald drop-in | systemd config | Persistent | Caps journal storage at 200M (`SystemMaxUse=200M`) |
| dcdown | shell function + alias | On demand | `docker compose down --rmi local --remove-orphans` with confirmation prompt |

## Configuration

### Heartbeat Port

The TCP port used for the heartbeat connection defaults to `19999`. To change it:

1. Set `WSL_HEARTBEAT_PORT` in the systemd service environment (the installer handles this via `--port`)
2. Set the same `WSL_HEARTBEAT_PORT` environment variable for the Windows scheduled task

### Install Directory

The default install directory is `/opt/wsl-disk-optimizer`. Override with `--install-dir` during installation. The uninstaller reads the install location from a marker file, so it works regardless of the directory used.

### Docker Daemon Optimization (Optional)

For additional Docker log management, you can configure the Docker daemon directly. This is not installed automatically:

```json
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

Add this to your Docker `daemon.json` and restart the Docker daemon.

## Uninstall

Remove Linux components:

```bash
sudo ./uninstall.sh
```

Then remove the Windows scheduled task and scripts in an elevated PowerShell session:

```powershell
Unregister-ScheduledTask -TaskName "WSL-Disk-Optimizer" -Confirm:$false
Remove-Item -Recurse "$env:ProgramData\wsl-disk-optimizer"
```

## How VHDX Compaction Works

WSL2 stores its filesystem in VHDX (Virtual Hard Disk) files. These virtual disks grow automatically as data is written but never shrink when data is deleted. Over time, this leads to significant wasted space on the Windows host.

The reclamation process has two steps:

1. **fstrim** -- Tells the ext4 filesystem inside WSL to release blocks that are no longer in use. This marks the freed space as reclaimable in the VHDX.

2. **VHDX compaction** -- Rewrites the VHDX file on the Windows host to remove the released blocks. Uses `Optimize-VHD` (Hyper-V module) when available, falling back to `diskpart` otherwise.

This tool automates the full pipeline: detect WSL shutdown via TCP connection loss, run `fstrim` (via the heartbeat service's `ExecStop`), wait for the WSL VM to fully terminate (`vmmem` exit + VHDX unlock), then compact all discovered VHDX files.

### VHDX Discovery

The compaction script discovers VHDX files by scanning all user profiles under `C:\Users\*\AppData\Local\` for:

- `wsl\{GUID}\ext4.vhdx` -- Modern WSL2 distributions
- `Packages\*\LocalState\ext4.vhdx` -- Store-installed distributions
- `Docker\wsl\data\ext4.vhdx` and `Docker\wsl\distro\ext4.vhdx` -- Docker Desktop

Override with the `WSL_VHDX_PATH` environment variable (comma or semicolon separated) to specify paths explicitly.

## Limitations

- **WSL2 only** -- WSL1 uses a translation layer, not a virtual disk, and is not supported.
- **Single WSL distribution** -- The heartbeat tracks one connection. Multi-distro tracking is planned for a future version.
- **Requires systemd** -- Available on WSL2 with Windows 11 22H2+ or Windows 10 with KB5020030+.
- **Windows watcher runs as SYSTEM** -- Administrator privileges are required for initial setup of the scheduled task.

## License

[MIT](LICENSE)
