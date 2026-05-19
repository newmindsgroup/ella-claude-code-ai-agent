#!/usr/bin/env bash
# start-embedding-daemon.sh — ensure the embedding service daemon is running.
# Idempotent: does nothing if already running.
# Called by: claude-agent startup, memory-vault.sh (lazy start), or manually.

set -euo pipefail

AGENT_HOME="${TENANT_AGENT_HOME:-{{TENANT_AGENT_HOME}}}"
DAEMON="$AGENT_HOME/scripts/embedding-service.py"
SOCKET="/tmp/{{TENANT_LINUX_USER}}-embedding.sock"
LOG="$AGENT_HOME/logs/embedding-service.log"
PIDFILE="$AGENT_HOME/logs/embedding-service.pid"

mkdir -p "$AGENT_HOME/logs"

is_running() {
    if [[ -f "$PIDFILE" ]]; then
        pid=$(cat "$PIDFILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    if [[ -S "$SOCKET" ]]; then
        # Try a quick connect test
        python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(1.0)
try:
    s.connect('$SOCKET')
    s.close()
    sys.exit(0)
except: sys.exit(1)
" 2>/dev/null && return 0
    fi
    return 1
}

if is_running; then
    echo "embedding-service: already running"
    exit 0
fi

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting embedding service..." >> "$LOG"

nohup python3 "$DAEMON" >> "$LOG" 2>&1 &
PID=$!
echo "$PID" > "$PIDFILE"

# Wait for socket to appear (max 20s)
for i in $(seq 1 40); do
    sleep 0.5
    if [[ -S "$SOCKET" ]]; then
        echo "embedding-service: started (PID=$PID, socket ready)"
        exit 0
    fi
done

echo "embedding-service: WARNING — socket did not appear after 20s (PID=$PID)"
exit 1
