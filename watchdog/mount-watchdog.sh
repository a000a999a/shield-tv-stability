#!/bin/bash
# ── Configuration ────────────────────────────────────────────────────────────
MOUNT="/mnt/nvidia"              # Local mount point for the Shield SMB share
SYSTEMD_UNIT="mnt-nvidia.mount"  # systemd unit name (derived from mount path)
COMPOSE_FILE="$HOME/Projects/docker/arr-stack/docker-compose.yml"
SERVICES="radarr sonarr"         # Space-separated docker compose services to revive
LOG_FILE="$HOME/logs/shield/mount-watchdog.log"
# ─────────────────────────────────────────────────────────────────────────────

mkdir -p "$(dirname "$LOG_FILE")"
log() { echo "$(date -Iseconds) $*" >> "$LOG_FILE"; }

if timeout 10 ls "$MOUNT" > /dev/null 2>&1; then
    exit 0
fi

log "WARN: $MOUNT inaccessible — attempting remount"

if sudo -n /usr/bin/systemctl restart "$SYSTEMD_UNIT" 2>> "$LOG_FILE"; then
    sleep 3
    if timeout 10 ls "$MOUNT" > /dev/null 2>&1; then
        log "OK: remounted successfully"

        for svc in $SERVICES; do
            state=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null \
                | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    d = json.loads(line)
    if d.get('Service') == '$svc':
        print(d.get('State',''))
" 2>/dev/null)
            if [ "$state" != "running" ]; then
                log "INFO: restarting $svc (was: ${state:-unknown})"
                docker compose -f "$COMPOSE_FILE" up -d "$svc" >> "$LOG_FILE" 2>&1
            fi
        done
    else
        log "ERROR: remount succeeded but $MOUNT still inaccessible"
    fi
else
    log "ERROR: systemctl restart $SYSTEMD_UNIT failed"
fi
