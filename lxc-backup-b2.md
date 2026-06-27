# Proxmox LXC Backup to Backblaze B2

## Overview
Weekly automated LXC backup from prox host to Backblaze B2 with Telegram summary.
Backups are client-side encrypted via rclone crypt before upload.

## Setup Details

| Parameter | Value |
|---|---|
| Script | `/usr/local/bin/lxc-backup-b2.sh` |
| Log | `/var/log/lxc-backup-b2.log` |
| Local staging | `/mnt/data/public/backups/lxc/` |
| B2 bucket | `prox-lxc-backups` |
| rclone base remote | `b2lxc` |
| rclone crypt remote | `b2lxccrypt` |
| rclone config | `~/.config/rclone/rclone.conf` |
| Schedule | Sunday 03:00 cron on prox host |
| Compression | zstd |
| Local retention | 1 latest per CT (deleted before new dump) |
| B2 retention | 1 latest per CT (overwrite on each run) |
| Telegram | Separate bot (token + chat ID in script) |

## LXCs Backed Up

| CT ID | Name | Dump Size (first run) |
|---|---|---|
| 107 | adguard | 301.0 MB |
| 101 | npm | 620.7 MB |
| 106 | openwrt | 9.0 MB |
| 105 | NAS | 75.4 MB |
| 103 | aria2 | 792.3 MB |
| 110 | tailscale | 296.9 MB |
| **Total** | | **~2.0 GB** |

## Flow

1. For each CT: delete previous local dump → vzdump (zstd, snapshot mode) → rclone sync to B2
2. Failures do not abort the run — all CTs are always attempted
3. Telegram summary sent at end with per-CT status, sizes, B2 before/after, duration

## rclone Setup (on prox host)

- Installed via `apt install rclone` (v1.60.1)
- `b2lxc` — Backblaze B2 base remote, scoped to `prox-lxc-backups` bucket
- `b2lxccrypt` — crypt remote on top of `b2lxc:prox-lxc-backups`, filename + directory encryption enabled, 128-bit generated passwords

> ⚠️ `~/.config/rclone/rclone.conf` contains the encrypted passwords. Back it up — without it the B2 data is unrecoverable.

## Notes

- CT 106 (openwrt) is `ostype: unmanaged` — backs up fine but not restorable via `pct restore`
- Local staging uses `/mnt/data` SSD (469 GB) — only 1 dump file per CT exists at any time so space impact is minimal (~2 GB)
- Local copies accessible via Samba: `\\192.168.0.10\public\backups\lxc\`
- ⚠️ If asked to modify/debug `lxc-backup-b2.sh`, ask for the current script first

## Script

```bash
#!/bin/bash
# =============================================================================
# Proxmox LXC Backup → Backblaze B2 (encrypted via rclone crypt)
# Host: prox (192.168.0.50)
# Schedule: Sunday 03:00 via cron
# Staging: /mnt/data/public/backups/lxc/
# B2 remote: b2lxccrypt (configure below)
# =============================================================================

# --- Config ------------------------------------------------------------------
TELEGRAM_TOKEN="YOUR_BOT_TOKEN_HERE"
TELEGRAM_CHAT_ID="YOUR_CHAT_ID_HERE"

CTIDS=(107 101 106 105 103 110)
CT_NAMES=(
    [107]="adguard"
    [101]="npm"
    [106]="openwrt"
    [105]="NAS"
    [103]="aria2"
    [110]="tailscale"
)

STAGING_DIR="/mnt/data/public/backups/lxc"
RCLONE_REMOTE="b2lxccrypt"    # rclone crypt remote name (configure during setup)
B2_BUCKET_PATH="${RCLONE_REMOTE}:prox-lxc-backups"
VZDUMP_OPTS="--compress zstd --mode snapshot --quiet 1"
LOG="/var/log/lxc-backup-b2.log"

# --- Helpers -----------------------------------------------------------------
TS() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(TS)] $*" | tee -a "$LOG"; }

tg_send() {
    local msg="$1"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=${msg}" \
        > /dev/null
}

human_size() {
    local bytes="$1"
    if   [ "$bytes" -ge $((1024*1024*1024)) ]; then printf "%.1f GB" "$(echo "scale=1; $bytes/1073741824" | bc)"
    elif [ "$bytes" -ge $((1024*1024))      ]; then printf "%.1f MB" "$(echo "scale=1; $bytes/1048576"    | bc)"
    else printf "%.1f KB" "$(echo "scale=1; $bytes/1024" | bc)"
    fi
}

rclone_size_bytes() {
    local path="$1"
    rclone size --json "$path" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('bytes',0))" 2>/dev/null || echo 0
}

# --- Pre-flight --------------------------------------------------------------
mkdir -p "$STAGING_DIR"
: > "$LOG"

START_EPOCH=$(date +%s)
log "=== LXC backup run started ==="

B2_SIZE_BEFORE=$(rclone_size_bytes "$B2_BUCKET_PATH")
log "B2 size before: $(human_size "$B2_SIZE_BEFORE")"

# --- Per-LXC backup loop -----------------------------------------------------
declare -A CT_STATUS CT_SIZE CT_ERR

for CTID in "${CTIDS[@]}"; do
    NAME="${CT_NAMES[$CTID]}"
    log "--- Backing up CT ${CTID} (${NAME}) ---"

    rm -f "${STAGING_DIR}"/vzdump-lxc-${CTID}-*.tar.zst \
          "${STAGING_DIR}"/vzdump-lxc-${CTID}-*.tar.zst.log
    log "CT${CTID}: Cleared old local dump"

    if vzdump "$CTID" --dumpdir "$STAGING_DIR" $VZDUMP_OPTS >> "$LOG" 2>&1; then
        DUMP_FILE=$(ls -t "${STAGING_DIR}"/vzdump-lxc-${CTID}-*.tar.zst 2>/dev/null | head -1)

        if [ -z "$DUMP_FILE" ]; then
            CT_STATUS[$CTID]="❌ FAIL"
            CT_ERR[$CTID]="vzdump succeeded but no output file found"
            log "CT${CTID}: ERROR — no output file"
            continue
        fi

        DUMP_BYTES=$(stat -c%s "$DUMP_FILE" 2>/dev/null || echo 0)
        CT_SIZE[$CTID]=$(human_size "$DUMP_BYTES")
        log "CT${CTID}: dump OK → $(basename "$DUMP_FILE") (${CT_SIZE[$CTID]})"

        DEST="${B2_BUCKET_PATH}/${NAME}/"
        log "CT${CTID}: uploading to ${DEST} ..."
        if rclone sync "$DUMP_FILE" "$DEST" --progress 2>> "$LOG"; then
            CT_STATUS[$CTID]="✅ OK"
            log "CT${CTID}: upload complete"
        else
            CT_STATUS[$CTID]="❌ FAIL"
            CT_ERR[$CTID]="rclone upload failed (exit $?)"
            log "CT${CTID}: upload FAILED"
        fi

    else
        CT_STATUS[$CTID]="❌ FAIL"
        CT_ERR[$CTID]="vzdump exited with error (exit $?)"
        log "CT${CTID}: vzdump FAILED"
    fi
done

# --- Post-run stats ----------------------------------------------------------
END_EPOCH=$(date +%s)
DURATION=$(( END_EPOCH - START_EPOCH ))
DURATION_FMT=$(printf '%dm %ds' $(( DURATION/60 )) $(( DURATION%60 )))

B2_SIZE_AFTER=$(rclone_size_bytes "$B2_BUCKET_PATH")
log "B2 size after: $(human_size "$B2_SIZE_AFTER")"
log "=== Run complete in ${DURATION_FMT} ==="

# --- Build Telegram message --------------------------------------------------
FAIL_COUNT=0
PER_CT_LINES=""
for CTID in "${CTIDS[@]}"; do
    NAME="${CT_NAMES[$CTID]}"
    STATUS="${CT_STATUS[$CTID]:-❓ UNKNOWN}"
    SIZE="${CT_SIZE[$CTID]:-—}"
    LINE="${STATUS} <b>CT${CTID} ${NAME}</b> — ${SIZE}"
    if [[ "${CT_ERR[$CTID]+_}" ]]; then
        LINE+=$'\n'"    ⚠️ ${CT_ERR[$CTID]}"
        (( FAIL_COUNT++ ))
    fi
    PER_CT_LINES+="${LINE}"$'\n'
done

if [ "$FAIL_COUNT" -eq 0 ]; then
    SUMMARY_ICON="✅"
    SUMMARY_TEXT="All LXC backups succeeded"
else
    SUMMARY_ICON="⚠️"
    SUMMARY_TEXT="${FAIL_COUNT} of ${#CTIDS[@]} backups FAILED"
fi

MSG="${SUMMARY_ICON} <b>Proxmox LXC Backup — $(date '+%a %d %b %Y')</b>
${SUMMARY_TEXT}

${PER_CT_LINES}
📦 B2 before: $(human_size "$B2_SIZE_BEFORE")
📦 B2 after:  $(human_size "$B2_SIZE_AFTER")
⏱ Duration:  ${DURATION_FMT}"

tg_send "$MSG"
log "Telegram summary sent"
```
