#!/bin/bash
set -euo pipefail

# Configuration
LIB_LOCAL="/mnt/nas/upload/library"
LIB_REMOTE="b2immichcrypt:immich-library"
LOG_FILE="/var/log/immich-library-backup.log"
STATS_DIR="/var/lib/immich-backup"
ERROR_FILE="$STATS_DIR/lib_error"
MAX_RETRIES=3
RETRY_DELAY=10

# Ensure stats directory exists
mkdir -p "$STATS_DIR"
rm -f "$ERROR_FILE"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Retry function for rclone size with validation and optional exclude
get_rclone_size() {
    local path="$1"
    local output_file="$2"
    local exclude_pattern="${3:-}"
    local attempt=1

    while [ $attempt -le $MAX_RETRIES ]; do
        log "Attempting to get size for $path (attempt $attempt/$MAX_RETRIES)"

        if [ -n "$exclude_pattern" ]; then
            log "Excluding pattern: $exclude_pattern"
            if rclone size "$path" --exclude "$exclude_pattern" > "$output_file" 2>&1; then
                if grep -q "Total objects:" "$output_file" && grep -q "Total size:" "$output_file"; then
                    log "Successfully retrieved size for $path (with exclusions)"
                    return 0
                fi
            fi
        else
            if rclone size "$path" > "$output_file" 2>&1; then
                if grep -q "Total objects:" "$output_file" && grep -q "Total size:" "$output_file"; then
                    log "Successfully retrieved size for $path"
                    return 0
                fi
            fi
        fi

        log "WARNING: Size output incomplete or command failed"

        if [ $attempt -lt $MAX_RETRIES ]; then
            log "Retrying in ${RETRY_DELAY}s..."
            sleep $RETRY_DELAY
        fi

        ((attempt++))
    done

    return 1
}

# ---- ADDED: helper to extract file count (used by guard) ----
extract_file_count() {
    grep "Total objects:" "$1" | sed 's/.*(\([0-9]*\)).*/\1/'
}

# Start backup
log "=========================================="
log "Starting Library Backup"
log "=========================================="

START_TIME=$(date +%s)

# Capture remote BEFORE stats
log "Capturing remote BEFORE stats..."
if ! get_rclone_size "$LIB_REMOTE" "$STATS_DIR/lib_before"; then
    log "FATAL: Cannot proceed without remote stats"
    echo "FAILED" > "$STATS_DIR/lib_status"
    echo "Remote library stats could not be retrieved. rclone size failed or returned incomplete data." > "$ERROR_FILE"
    exit 1
fi

# Capture local stats
log "Capturing local stats..."
if ! get_rclone_size "$LIB_LOCAL" "$STATS_DIR/lib_local"; then
    log "FATAL: Cannot proceed without local stats"
    echo "FAILED" > "$STATS_DIR/lib_status"
    echo "Local library stats could not be retrieved. Check mount and permissions for $LIB_LOCAL." > "$ERROR_FILE"
    exit 1
fi

# ---- ADDED: MASS DELETION PROTECTION GUARD ----
REMOTE_FILES=$(extract_file_count "$STATS_DIR/lib_before")
LOCAL_FILES=$(extract_file_count "$STATS_DIR/lib_local")

log "Sanity check: local files=$LOCAL_FILES, remote files=$REMOTE_FILES"

if [ "$REMOTE_FILES" -gt 0 ]; then
    THRESHOLD=$((REMOTE_FILES * 70 / 100))

    if [ "$LOCAL_FILES" -lt "$THRESHOLD" ]; then
        log "FATAL: Local file count ($LOCAL_FILES) below safety threshold ($THRESHOLD)"
        echo "FAILED" > "$STATS_DIR/lib_status"
        echo "Mass-deletion protection triggered. Local file count ($LOCAL_FILES) is far lower than remote ($REMOTE_FILES). Sync aborted to prevent data loss." > "$ERROR_FILE"
        exit 1
    fi
fi
# ---- END GUARD ----

# Perform sync
log "Starting rclone sync..."
SYNC_START=$(date +%s)

if rclone sync "$LIB_LOCAL" "$LIB_REMOTE" \
    --fast-list --transfers=4 --checkers=8 --metadata --skip-links \
    --stats-one-line --stats=30s \
    >> "$LOG_FILE" 2>&1; then

    SYNC_END=$(date +%s)
    SYNC_DURATION=$((SYNC_END - SYNC_START))
    echo "$SYNC_DURATION" > "$STATS_DIR/lib_duration"
    log "Sync completed successfully in ${SYNC_DURATION}s"
else
    log "ERROR: Sync failed"
    echo "FAILED" > "$STATS_DIR/lib_status"
    echo "rclone sync failed. Check network, credentials, or remote availability." > "$ERROR_FILE"
    exit 1
fi

# Capture remote AFTER stats
log "Capturing remote AFTER stats..."
if ! get_rclone_size "$LIB_REMOTE" "$STATS_DIR/lib_after"; then
    log "WARNING: Cannot verify sync completion"
    echo "PARTIAL" > "$STATS_DIR/lib_status"
    echo "Post-sync remote stats could not be retrieved. Sync may have completed but verification failed." > "$ERROR_FILE"
else
    echo "SUCCESS" > "$STATS_DIR/lib_status"
fi

END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))

log "Library backup completed in ${TOTAL_DURATION}s"
log "=========================================="
