#!/bin/bash
# ── Configuration ────────────────────────────────────────────────────────────
SHIELD_IP="192.168.1.x"          # ADB-over-Wi-Fi address of your Shield
SHIELD="${SHIELD_IP}:5555"
LOG_DIR="$HOME/logs/shield"      # Where to write daily logcat files
LOG_RETENTION_DAYS=14
# ─────────────────────────────────────────────────────────────────────────────

mkdir -p "$LOG_DIR"

while true; do
    LOGFILE="$LOG_DIR/logcat-$(date +%Y-%m-%d).log"

    find "$LOG_DIR" -name "logcat-*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null

    /usr/bin/adb connect "$SHIELD" > /dev/null 2>&1

    if /usr/bin/adb -s "$SHIELD" get-state 2>/dev/null | grep -q "^device$"; then
        echo "--- connected $(date -Iseconds) ---" >> "$LOGFILE"
        /usr/bin/adb -s "$SHIELD" logcat -v time >> "$LOGFILE" 2>&1
        echo "--- disconnected $(date -Iseconds) ---" >> "$LOGFILE"
    fi

    sleep 15
done
