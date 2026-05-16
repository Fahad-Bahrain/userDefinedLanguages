#!/bin/ksh
# =============================================================================
#  One-time setup: install tsm_drm_daily_backup.sh and cron entry
#  Run as: tsminst2  from /home/tsminst2
#  AIX 7.2 compatible
# =============================================================================

SCRIPT_PATH="/home/tsminst2/tsm_drm_daily_backup.sh"
LOG_DIR="/home/tsminst2/logs"
TEMP_DIR="/home/tsminst2/temp"

# 1. Create required directories (all under tsminst2 home – no root needed)
mkdir -p "$LOG_DIR" "$TEMP_DIR" && echo "Directories OK: $LOG_DIR  $TEMP_DIR"

# 2. Fix line endings in case file was transferred from Windows (CRLF -> LF)
#    AIX tr approach – works without GNU sed
if [ -f "$SCRIPT_PATH" ]; then
    cp "$SCRIPT_PATH" "${SCRIPT_PATH}.bak"
    tr -d '\r' < "${SCRIPT_PATH}.bak" > "$SCRIPT_PATH"
    rm -f "${SCRIPT_PATH}.bak"
    echo "Line endings fixed: $SCRIPT_PATH"
else
    echo "ERROR: $SCRIPT_PATH not found. Make sure the file is in /home/tsminst2/"
    exit 1
fi

# 3. Make script executable
chmod 750 "$SCRIPT_PATH"
echo "Permissions set: chmod 750 $SCRIPT_PATH"

# 4. Add cron entry (daily 19:00) – skip if already present
CRON_ENTRY="0 19 * * * $SCRIPT_PATH >> $LOG_DIR/cron_drm.log 2>&1"

if crontab -l 2>/dev/null | grep -q "tsm_drm_daily_backup"; then
    echo "Cron entry already exists – no change made."
else
    ( crontab -l 2>/dev/null; echo "$CRON_ENTRY" ) | crontab -
    echo "Cron entry added: $CRON_ENTRY"
fi

echo ""
echo "=== Current crontab for $(id -un) ==="
crontab -l

echo ""
echo "=== Setup complete ==="
echo "Script    : $SCRIPT_PATH"
echo "Logs      : $LOG_DIR/"
echo "Temp files: $TEMP_DIR/"
echo ""
echo "To test now, run:"
echo "  $SCRIPT_PATH"
echo "  tail -f $LOG_DIR/tsm_drm_*.log"
