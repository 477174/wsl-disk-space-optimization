#!/bin/bash
# WSL Heartbeat Client — maintains TCP connection to Windows watcher
# When this connection drops (WSL shutdown/crash), Windows triggers VHDX compaction

HOST="localhost"
PORT="${WSL_HEARTBEAT_PORT:-19999}"

exec 3<>/dev/tcp/$HOST/$PORT 2>/dev/null || { echo "Failed to connect to $HOST:$PORT"; exit 1; }
echo "Connected to $HOST:$PORT"

while true; do
  if read -t 10 -u 3 line; then
    line="${line%$'\r'}"
    [[ "$line" == "PING" ]] && echo "PONG" >&3
  else
    echo "Connection lost or timeout"
    break
  fi
done

exec 3>&- 2>/dev/null
exit 1
