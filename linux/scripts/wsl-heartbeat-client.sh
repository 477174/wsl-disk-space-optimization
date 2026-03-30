#!/bin/bash
# WSL Heartbeat Client — maintains TCP connection to Windows watcher
# When this connection drops (WSL shutdown/crash), Windows triggers VHDX compaction

HOST="localhost"
PORT="${WSL_HEARTBEAT_PORT:-19999}"

exec 3<>/dev/tcp/$HOST/$PORT 2>/dev/null || { echo "Failed to connect to $HOST:$PORT"; exit 1; }
echo "Connected to $HOST:$PORT"

cat <&3 >/dev/null

exec 3>&- 2>/dev/null
exit 1
