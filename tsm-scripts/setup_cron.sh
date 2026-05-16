#!/bin/ksh
# =============================================================================
#  One-time setup: install tsm_drm_daily_backup.sh cron entry
#  Run as: tsminst2
# =============================================================================

SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)/tsm_drm_daily_backup.sh"
SCRIPT_DEST="/home/tsminst2/scripts/tsm_drm_daily_backup.sh"
CRON_ENTRY="0 19 * * * $SCRIPT_DEST >> /home/tsminst2/logs/cron_drm.log 2>&1"

# 1. Create target directories
mkdir -p /home/tsminst2/scripts /home/tsminst2/logs /temp

# 2. Copy script and make executable
cp "$SCRIPT_SRC" "$SCRIPT_DEST"
chmod 750 "$SCRIPT_DEST"
echo "Script installed: $SCRIPT_DEST"

# 3. Add cron entry (skip if already present)
if crontab -l 2>/dev/null | grep -q "tsm_drm_daily_backup"; then
    echo "Cron entry already exists – skipping."
else
    (crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -
    echo "Cron entry added: $CRON_ENTRY"
fi

echo ""
echo "Setup complete. Crontab:"
crontab -l
