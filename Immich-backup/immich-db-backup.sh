#!/bin/bash
set -euo pipefail

# Configuration
DB_LOCAL="/mnt/nas/upload/backups"
DB_REMOTE="b2immichcrypt:immich-db"
LOG_FILE="/var/log/immich-db-weekly-sync.log"
STATS_DIR="/var/lib/immich-backup"
ERROR_FILE="$STATS_DIR/db_error"
MAX_RETRIES=3
RETRY_DELAY=10

mkdir -p "$STATS_DIR"
rm -f "$ERROR_FILE"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Stats capture
capture_stats() {
    local path="$1"
    local output_file="$2"
    local attempt=1

    while [ $attempt -le $MAX_RETRIES ]; do
        log "Capturing stats for $path (attempt $attempt/$MAX_RETRIES)..."

        if rclone size "$path" > "$output_file" 2>&1; then
            if grep -q "Total objects:" "$output_file"; then
                local count
                count=$(grep "Total objects:" "$output_file" | awk '{print $3}')
                log "✓ Captured: $count files"
                return 0
            fi
        fi

        log "WARNING: Stats capture failed"
        [ $attempt -lt $MAX_RETRIES ] && sleep $RETRY_DELAY
        ((attempt++))
    done

    return 1
}

log "=========================================="
log "Starting Database Backup"
log "=========================================="

START_TIME=$(date +%s)

# --- Remote BEFORE ---
if ! capture_stats "$DB_REMOTE" "$STATS_DIR/db_before"; then
    log "FATAL: Cannot read remote DB stats"
    echo "FAILED" > "$STATS_DIR/db_status"
    echo "Remote DB stats could not be retrieved." > "$ERROR_FILE"
    exit 1
fi

# --- Local ---
if ! capture_stats "$DB_LOCAL" "$STATS_DIR/db_local"; then
    log "FATAL: Cannot read local DB stats"
    echo "FAILED" > "$STATS_DIR/db_status"
    echo "Local DB path unreadable: $DB_LOCAL" > "$ERROR_FILE"
    exit 1
fi

# -------------------------------
# MASS DELETION GUARD (DB)
# -------------------------------
REMOTE_FILES=$(grep "Total objects:" "$STATS_DIR/db_before" | awk '{print $3}')
LOCAL_FILES=$(grep "Total objects:" "$STATS_DIR/db_local" | awk '{print $3}')

if [ "$LOCAL_FILES" -eq 0 ]; then
    log "FATAL: Local DB backup has 0 files — aborting to prevent wipe"
    echo "FAILED" > "$STATS_DIR/db_status"
    echo "Local DB backup directory is empty. Aborted to prevent deleting remote backups." > "$ERROR_FILE"
    exit 1
fi

if [ "$REMOTE_FILES" -gt 0 ] && [ "$LOCAL_FILES" -lt $((REMOTE_FILES / 2)) ]; then
    log "FATAL: Suspicious DB file drop (remote=$REMOTE_FILES local=$LOCAL_FILES)"
    echo "FAILED" > "$STATS_DIR/db_status"
    echo "DB file count dropped dangerously (remote=$REMOTE_FILES, local=$LOCAL_FILES). Sync aborted." > "$ERROR_FILE"
    exit 1
fi
# -------------------------------

# --- Sync ---
log "Starting rclone sync..."
SYNC_START=$(date +%s)

if rclone sync "$DB_LOCAL" "$DB_REMOTE" \
    --fast-list --transfers=1 --checkers=4 --metadata --skip-links \
    --stats-one-line --stats=30s \
    >> "$LOG_FILE" 2>&1; then

    SYNC_END=$(date +%s)
    echo $((SYNC_END - SYNC_START)) > "$STATS_DIR/db_duration"
    log "✓ Sync completed"
else
    log "ERROR: DB sync failed"
    echo "FAILED" > "$STATS_DIR/db_status"
    echo "rclone sync failed for DB backup." > "$ERROR_FILE"
    exit 1
fi

# --- Remote AFTER ---
if ! capture_stats "$DB_REMOTE" "$STATS_DIR/db_after"; then
    echo "PARTIAL" > "$STATS_DIR/db_status"
    echo "Post-sync DB stats unavailable." > "$ERROR_FILE"
else
    echo "SUCCESS" > "$STATS_DIR/db_status"
fi

END_TIME=$(date +%s)
log "Database backup completed in $((END_TIME - START_TIME))s"
log "=========================================="
