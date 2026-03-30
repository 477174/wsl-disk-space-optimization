# Architecture

Technical architecture documentation for the WSL Disk Space Optimization system.

---

## Overview

The system reclaims disk space consumed by WSL2 VHDX virtual disks through three
coordinated subsystems: Docker cleanup, WSL maintenance, and VHDX compaction.

```
+------------------+     +-------------------+     +------------------+
| Docker Cleanup   |     | WSL Maintenance   |     | VHDX Compaction  |
| - GC daemon      |     | - Memory cleanup  |     | - TCP watcher    |
| - Weekly prune   |     | - Cache cleanup   |     | - Heartbeat      |
|                  |     | - History dedup   |     | - Compaction     |
|                  |     | - Journal cap     |     | - fstrim         |
+------------------+     +-------------------+     +------------------+
      systemd                   systemd              systemd + Task Sched
```

**Docker Cleanup** runs inside WSL via systemd. A long-running GC daemon watches
for stopped containers and dangling images. A weekly timer runs a full
`docker system prune -af`.

**WSL Maintenance** runs inside WSL via systemd timers. Periodic tasks drop page
caches, clean package manager caches, deduplicate zsh history, and cap journald
storage at 200 MB.

**VHDX Compaction** spans both sides of the boundary. A TCP heartbeat client
inside WSL maintains a persistent connection to a Windows-side watcher process.
When the connection drops (graceful shutdown, termination, or crash), the watcher
runs `fstrim`, shuts down WSL, and compacts the VHDX files.

### Cross-Boundary Communication

```
  WSL (Linux)                            Windows
 +--------------------------+           +--------------------------+
 | wsl-heartbeat-client.sh  |-- TCP --->| wsl-compact-watcher.ps1  |
 | (systemd managed)        | loopback  | (Task Scheduler managed) |
 |                          | :19999    |                          |
 | ExecStop: fstrim -v /    |           | Fallback: fstrim -av     |
 +--------------------------+           | compact-wsl.ps1          |
                                        +--------------------------+
```

The heartbeat uses TCP over loopback (`127.0.0.1:19999`). The port is
configurable via the `WSL_HEARTBEAT_PORT` environment variable on both sides.

---

## TCP Watcher Design

### Why TCP

Alternative approaches were considered and rejected:

| Approach | Problem |
|----------|---------|
| systemd lifecycle hooks only | Unreliable for `wsl --terminate` and crashes -- ExecStop does not run |
| Polling `wsl --list --running` | Wastes CPU cycles; adds latency; misses rapid stop-start sequences |
| Named pipes / Unix sockets | Cannot cross the WSL-to-Windows boundary natively |
| File-based heartbeat | Race conditions; filesystem caching delays; no crash detection |
| Windows event log monitoring | Unreliable event sequencing; no events for VM crashes |

TCP was chosen because:

1. It works across the WSL/Windows boundary via loopback.
2. Socket FIN provides sub-second detection of graceful shutdown.
3. TCP keepalive detects VM crashes within approximately 15 seconds.
4. Application-level PING/PONG catches network stack failures within approximately 8 seconds.
5. The connection model is simple: one listener, one client, one state machine.

### State Machine

```
                         accept
    LISTENING ─────────────────────> CONNECTED
        ^                               |
        |                          disconnect detected
        |                          (FIN / keepalive / heartbeat)
        |                               |
        |                               v
        |                          DISCONNECTED
        |                               |
        |                          30s grace period
        |                          (check every 5s if WSL restarted)
        |                               |
        |           [WSL restarted]     |     [WSL still down]
        |<──────────────────────────────+─────────────> COMPACTING
        |                                                   |
        |                                              fstrim + shutdown
        |                                              triple-check
        |                                              compact-wsl.ps1
        |                                                   |
        +<──────────────────────────────────────────────────+
```

### State Transitions

**LISTENING -> CONNECTED**

The watcher binds to `127.0.0.1:$Port` and blocks on `AcceptTcpClient()`. When
the heartbeat client inside WSL connects, the watcher transitions to CONNECTED.
TCP keepalive is configured on the accepted socket: 5 seconds idle time,
1 second probe interval.

**CONNECTED -> DISCONNECTED**

Three independent mechanisms detect disconnection:

1. **Socket FIN** -- `Socket.Poll(SelectRead)` returns true and
   `Socket.Available` equals 0. This catches graceful shutdown (`wsl --shutdown`)
   and clean termination (`wsl --terminate`). Detection time: less than 1 second.

2. **TCP keepalive timeout** -- The OS sends keepalive probes after 5 seconds of
   idle time, retrying every 1 second. After approximately 10 failed probes
   (~15 seconds total), the socket reports an error. This catches VM crashes and
   hard kills.

3. **Application heartbeat timeout** -- Every 5 seconds the watcher sends `PING`
   and expects `PONG` within 3 seconds. If the response is missing or invalid,
   disconnection is declared. This catches network stack failures that TCP
   keepalive alone would miss (e.g., the process is alive but the bash `/dev/tcp`
   FD is broken). Detection time: approximately 8 seconds.

**DISCONNECTED -> LISTENING (cancel)**

During the 30-second grace period, the watcher checks every 5 seconds whether
WSL has restarted (`wsl --list --running`). If any distro is running, compaction
is cancelled and the watcher returns to LISTENING.

**DISCONNECTED -> COMPACTING**

After the grace period expires with no WSL restart detected, the watcher enters
the compaction pipeline (described below).

**COMPACTING -> LISTENING**

After compaction completes (or fails), the watcher returns to LISTENING and
waits for the next heartbeat client connection.

---

## Detection Methods

| Scenario | Detection Method | Timing | fstrim Source |
|----------|-----------------|--------|---------------|
| Graceful `wsl --shutdown` | Socket FIN + ExecStop | <1s | ExecStop (systemd) |
| `wsl --terminate` | Socket FIN | <1s | Watcher fallback |
| WSL crash / VM crash | TCP keepalive timeout | ~15s | Watcher fallback |
| Network stack failure | Heartbeat PONG timeout | ~8s | Watcher fallback |
| Windows reboot | N/A (watcher stops too) | N/A | N/A |

### Dual fstrim Strategy

On graceful shutdown, systemd runs `ExecStop=/usr/sbin/fstrim -v /` inside WSL
before the heartbeat client exits. This is the preferred path because fstrim runs
while the filesystem is still mounted and stable.

On non-graceful shutdown (terminate, crash), ExecStop does not execute. The
watcher runs `wsl -u root -e fstrim -av` as a fallback. This briefly restarts
WSL to perform the trim, then immediately shuts it down again before compaction.

### Heartbeat Protocol

```
  Watcher (Windows)              Client (WSL)
       |                              |
       |<-------- TCP connect --------|
       |                              |
       |------- "PING\n" ------------>|
       |                              |
       |<------ "PONG\n" -------------|
       |                              |
       |   ... repeats every 5s ...   |
       |                              |
       |------- "PING\n" ------------>|
       |                              |
       |   (no response within 3s)    |
       |                              |
       | -> disconnect declared       |
```

The client uses bash `/dev/tcp` for the connection -- no external dependencies
required. It reads with `read -t 10` (10-second timeout), strips carriage
returns, and writes `PONG` back on match.

---

## Compaction Pipeline

When disconnection is confirmed:

```
Step 1: Log disconnect reason
          |
Step 2: Enter 30s grace period
          |  - Check every 5s if WSL restarted
          |  - If restarted: cancel, return to LISTENING
          |
Step 3: Run fallback fstrim
          |  - wsl -u root -e fstrim -av
          |  - Briefly restarts WSL to trim
          |  - Logs output line by line
          |
Step 4: Shut down WSL
          |  - wsl --shutdown
          |  - Wait up to 60s for full shutdown
          |  - Poll: wsl --list --running + Get-Process vmmem
          |  - If timeout: abort compaction
          |
Step 5: Triple-check gate
          |  - wsl --list --running -> must return no distros
          |  - Get-Process vmmem -> must not exist
          |  - VHDX file lock test -> must not be locked
          |  - If ANY check fails: abort compaction
          |
Step 6: Compact VHDX files
          |  - Invoke compact-wsl.ps1
          |  - Uses Optimize-VHD (Hyper-V) if available
          |  - Falls back to diskpart compact otherwise
          |  - Logs before/after sizes and savings per file
          |
Step 7: Return to LISTENING
```

### Triple-Check Gate Detail

The triple-check prevents compacting a VHDX that is still in use:

1. **Running distros** -- `wsl --list --running` is parsed, filtering out header
   lines. Any running distro name fails the check.

2. **vmmem process** -- `Get-Process -Name vmmem` detects the WSL2 lightweight
   VM. If vmmem exists, the VM is still running.

3. **VHDX file lock** -- Each discovered VHDX path is opened with
   `[System.IO.File]::Open(path, Open, ReadWrite, None)`. If the open succeeds,
   the file is not locked and compaction can proceed. If it throws, another
   process (Hyper-V, backup software) holds a lock.

### VHDX Discovery

The watcher discovers VHDX files automatically:

1. If `WSL_VHDX_PATH` is set, it splits on `,` or `;` and uses those paths.
2. Otherwise, it scans `$env:LOCALAPPDATA\Packages\*\LocalState\ext4.vhdx`.
3. It also checks Docker Desktop paths:
   - `$env:LOCALAPPDATA\Docker\wsl\data\ext4.vhdx`
   - `$env:LOCALAPPDATA\Docker\wsl\distro\ext4.vhdx`

The compaction script (`compact-wsl.ps1`) performs its own discovery with a
similar algorithm, filtering package directories by known distro name patterns
(Ubuntu, Debian, SUSE, Kali, Fedora, Canonical).

### Compaction Methods

`compact-wsl.ps1` tries two methods in order:

1. **Optimize-VHD** (Hyper-V module) -- `Optimize-VHD -Path $vhdx -Mode Full`.
   Available on Windows Pro/Enterprise with Hyper-V enabled.

2. **diskpart** -- Generates a script: `select vdisk file=...\ncompact vdisk\ndetach vdisk`.
   Available on all Windows editions. Requires administrator privileges.

---

## Edge Cases

### Crash (no ExecStop fstrim)

When WSL crashes or is terminated with `wsl --terminate`, systemd ExecStop does
not run. The watcher detects the disconnection via TCP keepalive or heartbeat
timeout and runs `wsl -u root -e fstrim -av` as a fallback before compaction.
This briefly restarts WSL solely to perform the filesystem trim.

### WSL Restart During Grace Period

If a user runs `wsl` during the 30-second grace period, the watcher detects the
restart via `wsl --list --running` (polled every 5 seconds) and cancels
compaction. The watcher returns to LISTENING and waits for the heartbeat client
to reconnect.

### Locked VHDX (Backup Software)

If backup software, antivirus, or another process holds a file lock on the VHDX,
the triple-check gate fails at the lock test step. Compaction is skipped and the
reason is logged. The watcher returns to LISTENING and will retry on the next
WSL shutdown cycle.

### Disk Full

`fstrim` still functions on a full disk because it releases previously freed
blocks back to the host filesystem. The subsequent VHDX compaction may fail if
Windows needs temporary space for the diskpart operation. Failures are logged and
the watcher continues to the next cycle.

### Multiple VHDX Files

Both the watcher and `compact-wsl.ps1` discover all VHDX files via
`$env:LOCALAPPDATA` scanning. Each file is compacted independently in sequence.
A lock failure on one VHDX does not prevent compaction of others.

### Port Conflict

The default port (19999) is configurable via the `WSL_HEARTBEAT_PORT`
environment variable. Both sides read it: the watcher validates the value as an
integer in the 1-65535 range; the heartbeat client uses bash parameter expansion
with a default (`${WSL_HEARTBEAT_PORT:-19999}`). The installer accepts a
`--port` flag that writes the value into the systemd unit file.

### Watcher Crash (Windows Side)

The Task Scheduler task (`WSL-Disk-Optimizer`) is configured with:

- `RestartInterval`: 1 minute
- `RestartCount`: 999
- `ExecutionTimeLimit`: 0 (unlimited)
- `MultipleInstances`: IgnoreNew
- Trigger: at system startup with 10-second delay
- Principal: SYSTEM with Highest privileges

If the PowerShell process crashes, Task Scheduler restarts it within 1 minute.

### Heartbeat Client Crash (Linux Side)

The systemd service (`wsl-heartbeat.service`) is configured with:

- `Restart=always`
- `RestartSec=5`
- `TimeoutStopSec=120` (allows time for ExecStop fstrim on graceful shutdown)

If the bash process crashes, systemd restarts it within 5 seconds. The watcher
accepts the new TCP connection after the previous one disconnects.

---

## Component Reference

### Systemd Services and Timers (Linux)

| File | Type | Purpose |
|------|------|---------|
| `linux/systemd/docker-gc.service` | systemd service | Docker garbage collection daemon |
| `linux/systemd/docker-weekly-prune.service` | systemd service | Weekly `docker system prune -af` |
| `linux/systemd/docker-weekly-prune.timer` | systemd timer | Triggers weekly prune (Sun 03:00) |
| `linux/systemd/cache-cleanup.service` | systemd service | Package manager cache cleanup |
| `linux/systemd/cache-cleanup.timer` | systemd timer | Triggers cache cleanup (Sun 03:30) |
| `linux/systemd/wsl-mem-cleanup.service` | systemd service | Drop page cache and dentries |
| `linux/systemd/wsl-mem-cleanup.timer` | systemd timer | Triggers mem cleanup (every 30min) |
| `linux/systemd/zsh-history-cleanup.service` | systemd service | Deduplicate zsh history |
| `linux/systemd/zsh-history-cleanup.timer` | systemd timer | Triggers history cleanup (Sun 02:00) |
| `linux/systemd/wsl-heartbeat.service` | systemd service | TCP heartbeat client + ExecStop fstrim |

### Scripts (Linux)

| File | Type | Purpose |
|------|------|---------|
| `linux/scripts/docker-gc-daemon` | bash script | Docker GC daemon implementation |
| `linux/scripts/free-wsl-mem.sh` | bash script | Memory cleanup implementation |
| `linux/scripts/cache-cleanup.sh` | bash script | Cache cleanup implementation |
| `linux/scripts/zsh-history-cleanup` | bash script | History dedup implementation |
| `linux/scripts/wsl-heartbeat-client.sh` | bash script | TCP heartbeat client (`/dev/tcp/`) |

### Shell Aliases (Linux)

| File | Type | Purpose |
|------|------|---------|
| `linux/shell/dcdown.zsh` | zsh source | `dcdown` alias for zsh |
| `linux/shell/dcdown.bash` | bash source | `dcdown` alias for bash |

### Windows Components

| File | Type | Purpose |
|------|------|---------|
| `windows/compact-wsl.ps1` | PowerShell | VHDX compaction (Optimize-VHD / diskpart) |
| `windows/wsl-compact-watcher.ps1` | PowerShell | TCP watcher state machine |
| `windows/setup-watcher.ps1` | PowerShell | Task Scheduler registration |

### Top-Level

| File | Type | Purpose |
|------|------|---------|
| `install.sh` | bash script | Modular installer (flags per component) |
| `uninstall.sh` | bash script | Exhaustive uninstaller |

---

## Configuration

### Environment Variables

| Variable | Default | Used By | Description |
|----------|---------|---------|-------------|
| `WSL_HEARTBEAT_PORT` | `19999` | Watcher + heartbeat client | TCP port for heartbeat connection |
| `WSL_VHDX_PATH` | (auto-discover) | Watcher | Comma/semicolon-separated list of VHDX paths |

### Installer Flags

| Flag | Description |
|------|-------------|
| `--all` | Install all components (default when no flags given) |
| `--docker` | Install Docker cleanup components only |
| `--wsl` | Install WSL maintenance components only |
| `--watcher` | Install TCP watcher components only |
| `--shell` | Install shell aliases only |
| `--no-docker` | Exclude Docker components from `--all` |
| `--no-wsl` | Exclude WSL components from `--all` |
| `--no-watcher` | Exclude watcher components from `--all` |
| `--no-shell` | Exclude shell components from `--all` |
| `--install-dir DIR` | Installation directory (default: `/opt/wsl-disk-optimizer`) |
| `--port PORT` | Heartbeat port (default: `19999`) |

### Timing Parameters (Hardcoded)

| Parameter | Value | Location |
|-----------|-------|----------|
| Heartbeat interval | 5 seconds | `wsl-compact-watcher.ps1` |
| Heartbeat PONG timeout | 3 seconds | `wsl-compact-watcher.ps1` |
| Grace period | 30 seconds | `wsl-compact-watcher.ps1` |
| Grace period poll interval | 5 seconds | `wsl-compact-watcher.ps1` |
| TCP keepalive idle | 5 seconds | `wsl-compact-watcher.ps1` (IOControl) |
| TCP keepalive probe interval | 1 second | `wsl-compact-watcher.ps1` (IOControl) |
| WSL shutdown wait | 60 seconds max | `wsl-compact-watcher.ps1` |
| Client read timeout | 10 seconds | `wsl-heartbeat-client.sh` |
| Heartbeat restart delay | 5 seconds | `wsl-heartbeat.service` |
| Watcher restart delay | 1 minute | Task Scheduler settings |
| ExecStop timeout | 120 seconds | `wsl-heartbeat.service` |
