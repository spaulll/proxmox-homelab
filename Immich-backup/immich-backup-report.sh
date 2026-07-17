#!/bin/bash
set -euo pipefail

# ===================== CONFIG =====================
STATS_DIR="/var/lib/immich-backup"
DATE_NOW="$(date '+%Y-%m-%d %H:%M:%S')"

TG_BOT_TOKEN="TG_BOT_TOKEN"
TG_CHAT_ID="TG_CHAT_ID"

# Proxy toggle — set USE_PROXY=true and fill in credentials to enable
USE_PROXY=false
# PROXY_URL="socks5h://PROXY_USERNAME:PROXY_PASSWORD@10.10.10.218:8388"
# ==================================================

LIB_ERROR_FILE="$STATS_DIR/lib_error"
DB_ERROR_FILE="$STATS_DIR/db_error"

LIB_ERROR_MSG=""
DB_ERROR_MSG=""
[ -f "$LIB_ERROR_FILE" ] && LIB_ERROR_MSG=$(cat "$LIB_ERROR_FILE")
[ -f "$DB_ERROR_FILE"  ] && DB_ERROR_MSG=$(cat "$DB_ERROR_FILE")

# -------------------------
# Parse functions
# -------------------------
parse_files() {
    grep -oP 'Total objects: [\d.]+[kKmM]? \(\K[0-9]+' "$1" 2>/dev/null || echo "0"
}

parse_size_human() {
    grep "Total size:" "$1" 2>/dev/null | sed 's/Total size: \([0-9.]* [KMGT]*i*B\).*/\1/' || echo "N/A"
}

parse_bytes() {
    grep "Total size:" "$1" 2>/dev/null | sed 's/.* (\([0-9]*\) Byte)/\1/' || echo "0"
}

bytes_to_human() {
    local bytes=$1
    local abs_bytes=${bytes#-}
    local sign=""
    [ "$bytes" -lt 0 ] && sign="-"

    if   [ "$abs_bytes" -lt 1024 ];       then echo "${sign}${abs_bytes} B"
    elif [ "$abs_bytes" -lt 1048576 ];    then awk "BEGIN {printf \"${sign}%.2f KB\", $abs_bytes/1024}"
    elif [ "$abs_bytes" -lt 1073741824 ]; then awk "BEGIN {printf \"${sign}%.2f MB\", $abs_bytes/1048576}"
    else                                       awk "BEGIN {printf \"${sign}%.3f GB\", $abs_bytes/1073741824}"
    fi
}

format_duration() {
    local s=$1
    if [ "$s" -lt 60 ]; then echo "${s}s"
    else printf "%dm %02ds" $((s / 60)) $((s % 60))
    fi
}

calc_speed() {
    local bytes=$1
    local secs=$2
    local abs=${bytes#-}
    [ "$secs" -eq 0 ] && { echo "N/A"; return; }
    awk "BEGIN {printf \"%.2f MB/s\", $abs/1048576/$secs}"
}

format_delta() {
    local files_delta=$1
    local bytes_delta=$2
    local size_human
    size_human=$(bytes_to_human "$bytes_delta")

    if   [ "$files_delta" -eq 0 ] && [ "$bytes_delta" -eq 0 ]; then echo "No changes"
    elif [ "$files_delta" -gt 0 ]; then echo "+${files_delta} files (+${size_human})"
    else echo "${files_delta} files (${size_human})"
    fi
}

# -------------------------
# Telegram sender
# -------------------------
send_telegram() {
    local text="$1"
    local curl_args=(
        -s -X POST
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
        -d "chat_id=${TG_CHAT_ID}"
        -d "parse_mode=HTML"
        --data-urlencode "text=${text}"
    )

    if [ "$USE_PROXY" = true ] && [ -n "${PROXY_URL:-}" ]; then
        curl_args+=(--proxy "$PROXY_URL")
    fi

    curl "${curl_args[@]}" > /dev/null
}

# -------------------------
# Guard — required stat files
# -------------------------
SEP="━━━━━━━━━━━━━━━━━━━━"

for file in lib_before lib_local db_before db_local; do
    if [ ! -f "$STATS_DIR/$file" ]; then
        send_telegram "$(printf '📦 <b>Immich Backup Report</b>\n%s\n%s\n\n❌ <b>FATAL</b> — missing stats file: <code>%s</code>\nCheck logs:\n  /var/log/immich-library-backup.log\n  /var/log/immich-db-weekly-sync.log' "$DATE_NOW" "$SEP" "$file")"
        exit 1
    fi
done

# -------------------------
# Parse stats
# -------------------------
LIB_BEFORE_FILES=$(parse_files "$STATS_DIR/lib_before")
LIB_BEFORE_SIZE=$(parse_size_human "$STATS_DIR/lib_before")
LIB_BEFORE_BYTES=$(parse_bytes "$STATS_DIR/lib_before")

LIB_AFTER_FILES=0; LIB_AFTER_SIZE="N/A"; LIB_AFTER_BYTES=0
if [ -f "$STATS_DIR/lib_after" ]; then
    LIB_AFTER_FILES=$(parse_files "$STATS_DIR/lib_after")
    LIB_AFTER_SIZE=$(parse_size_human "$STATS_DIR/lib_after")
    LIB_AFTER_BYTES=$(parse_bytes "$STATS_DIR/lib_after")
fi

DB_BEFORE_FILES=$(parse_files "$STATS_DIR/db_before")
DB_BEFORE_SIZE=$(parse_size_human "$STATS_DIR/db_before")
DB_BEFORE_BYTES=$(parse_bytes "$STATS_DIR/db_before")

DB_AFTER_FILES=0; DB_AFTER_SIZE="N/A"; DB_AFTER_BYTES=0
if [ -f "$STATS_DIR/db_after" ]; then
    DB_AFTER_FILES=$(parse_files "$STATS_DIR/db_after")
    DB_AFTER_SIZE=$(parse_size_human "$STATS_DIR/db_after")
    DB_AFTER_BYTES=$(parse_bytes "$STATS_DIR/db_after")
fi

# -------------------------
# Deltas (|| true guards against set -e on zero result)
# -------------------------
LIB_FILES_DELTA=$(( LIB_AFTER_FILES  - LIB_BEFORE_FILES  )) || true
LIB_BYTES_DELTA=$(( LIB_AFTER_BYTES  - LIB_BEFORE_BYTES  )) || true
DB_FILES_DELTA=$((  DB_AFTER_FILES   - DB_BEFORE_FILES   )) || true
DB_BYTES_DELTA=$((  DB_AFTER_BYTES   - DB_BEFORE_BYTES   )) || true
TOTAL_FILES_DELTA=$(( LIB_FILES_DELTA + DB_FILES_DELTA   )) || true
TOTAL_BYTES_DELTA=$(( LIB_BYTES_DELTA + DB_BYTES_DELTA   )) || true

LIB_DELTA_DISPLAY=$(format_delta "$LIB_FILES_DELTA" "$LIB_BYTES_DELTA")
DB_DELTA_DISPLAY=$(format_delta  "$DB_FILES_DELTA"  "$DB_BYTES_DELTA")
TOTAL_CHANGE=$(bytes_to_human "$TOTAL_BYTES_DELTA")

# -------------------------
# Durations & speeds
# -------------------------
LIB_DURATION=$(cat "$STATS_DIR/lib_duration" 2>/dev/null || echo 0)
DB_DURATION=$(cat  "$STATS_DIR/db_duration"  2>/dev/null || echo 0)
TOTAL_DURATION=$(( LIB_DURATION + DB_DURATION )) || true

LIB_DURATION_FMT=$(format_duration "$LIB_DURATION")
DB_DURATION_FMT=$(format_duration  "$DB_DURATION")
TOTAL_DURATION_FMT=$(format_duration "$TOTAL_DURATION")

LIB_SPEED=$(calc_speed "$LIB_BYTES_DELTA" "$LIB_DURATION")
DB_SPEED=$(calc_speed  "$DB_BYTES_DELTA"  "$DB_DURATION")

# -------------------------
# Status & icons
# -------------------------
LIB_STATUS=$(cat "$STATS_DIR/lib_status" 2>/dev/null || echo "UNKNOWN")
DB_STATUS=$(cat  "$STATS_DIR/db_status"  2>/dev/null || echo "UNKNOWN")

status_icon() {
    case "$1" in
        SUCCESS) echo "✅ SUCCESS" ;;
        FAILED)  echo "❌ FAILED"  ;;
        PARTIAL) echo "⚠️ PARTIAL" ;;
        *)       echo "❓ UNKNOWN" ;;
    esac
}

LIB_STATUS_ICON=$(status_icon "$LIB_STATUS")
DB_STATUS_ICON=$(status_icon  "$DB_STATUS")

if   [ "$LIB_STATUS" = "SUCCESS" ] && [ "$DB_STATUS" = "SUCCESS" ]; then
    FOOTER="🟢 <b>ALL GOOD</b>  │  +${TOTAL_FILES_DELTA} files  ·  ${TOTAL_CHANGE}  ·  ${TOTAL_DURATION_FMT}"
elif [ "$LIB_STATUS" = "FAILED"  ] || [ "$DB_STATUS" = "FAILED"  ]; then
    FOOTER="🔴 <b>ISSUES DETECTED</b>  │  ${TOTAL_DURATION_FMT}"
else
    FOOTER="⚠️ <b>PARTIAL SUCCESS</b>  │  ${TOTAL_DURATION_FMT}"
fi

# -------------------------
# Error blocks (only shown on failure)
# -------------------------
lib_error_block=""
[ -n "$LIB_ERROR_MSG" ] && lib_error_block="$(printf '\n  ⚠️ %s' "$LIB_ERROR_MSG")"

db_error_block=""
[ -n "$DB_ERROR_MSG" ] && db_error_block="$(printf '\n  ⚠️ %s' "$DB_ERROR_MSG")"

# -------------------------
# Build & send message
# -------------------------
MSG="$(printf \
'📦 <b>Immich Backup Report</b>
%s
%s

📁 <b>Library</b>         %s
  Before  │ %s files / %s
  After   │ %s files / %s
  Changes │ %s
  Speed   │ %s · %s%s

%s

🗄️ <b>Database</b>        %s
  Before  │ %s files / %s
  After   │ %s files / %s
  Changes │ %s
  Speed   │ %s · %s%s

%s

%s' \
"$DATE_NOW" "$SEP" \
"$LIB_STATUS_ICON" \
"$LIB_BEFORE_FILES" "$LIB_BEFORE_SIZE" \
"$LIB_AFTER_FILES"  "$LIB_AFTER_SIZE" \
"$LIB_DELTA_DISPLAY" \
"$LIB_SPEED" "$LIB_DURATION_FMT" \
"$lib_error_block" \
"$SEP" \
"$DB_STATUS_ICON" \
"$DB_BEFORE_FILES" "$DB_BEFORE_SIZE" \
"$DB_AFTER_FILES"  "$DB_AFTER_SIZE" \
"$DB_DELTA_DISPLAY" \
"$DB_SPEED" "$DB_DURATION_FMT" \
"$db_error_block" \
"$SEP" \
"$FOOTER")"

send_telegram "$MSG"

# Clear error files after reporting
rm -f "$LIB_ERROR_FILE" "$DB_ERROR_FILE"

echo "Report sent to Telegram (chat: $TG_CHAT_ID)"
