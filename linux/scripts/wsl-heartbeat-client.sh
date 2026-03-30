#!/bin/bash
# WSL Heartbeat Client — maintains TCP connection to Windows watcher
# When this connection drops (WSL shutdown/crash), Windows triggers VHDX compaction

HOST="localhost"
PORT="${WSL_HEARTBEAT_PORT:-19999}"

exec 3<>/dev/tcp/$HOST/$PORT 2>/dev/null || { echo "Failed to connect to $HOST:$PORT"; exit 1; }
echo "Connected to $HOST:$PORT"

# Hold connection open — just wait for it to break
while read -t 30 -u 3 _ 2>/dev/null; do :; done

echo "Connection lost"

exec 3>&- 2>/dev/null
exit 1
