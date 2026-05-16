#!/bin/ksh
# =============================================================================
#  TSM DRM Daily Backup Automation Script
#  Server  : DR-EKKERP80
#  Instance: tsminst2
#  Schedule: Daily 7:00 PM via cron
#
#  Flow:
#   1. Check scratch tape availability in LTO6 library
#   2. Reclaim tapes in VaultRetrieve state → move to Onsite → checkin scratch
#   3. Delete expired volume history (>3 days old DB backup entries)
#   4. Run TSM DB full backup  (ba db type=full devc=ltoclass6)
#   5. Run PREPARE to generate disaster recovery files
#   6. Copy volhist.dat / devconf.dat / prepare-file to /temp  (7-day rotation)
#   7. Send email  →  SUCCESS  or  WARNING (no scratch) / ERROR (backup failed)
# =============================================================================

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
TSM_SERVER="DR-EKKERP80"
TSM_ADMIN_ID="admin"
TSM_ADMIN_PW="admin123"
TSM_LIBRARY="LTO6"
TSM_DEVCLASS="ltoclass6"
TSM_RETENTION_DAYS=3          # DB backup expires after 3 days
TEMP_DIR="/temp"
TEMP_KEEP_DAYS=7              # rotate /temp files older than 7 days

# TSM instance home (volhist.dat / devconf.dat live here)
TSM_INST_HOME="/home/tsminst2"

# dsmadmc binary path (AIX TSM 8.1)
DSMADMC="/usr/bin/dsmadmc"

EMAIL_TO="mohammed.fahad@ekkanoo.com.bh"
EMAIL_FROM="tsm-drm@ekkerp80"
SENDMAIL="/usr/sbin/sendmail"

SCRIPT_NAME="TSM_DRM_Backup"
LOG_DIR="/home/tsminst2/logs"
LOG_FILE="${LOG_DIR}/tsm_drm_$(date +%Y%m%d_%H%M%S).log"

# ---------------------------------------------------------------------------
# INIT
# ---------------------------------------------------------------------------
mkdir -p "$LOG_DIR" "$TEMP_DIR"

OVERALL_STATUS="SUCCESS"
EMAIL_SUBJECT=""
EMAIL_BODY=""
TAPE_RECLAIMED=""
BACKUP_VOL=""
BACKUP_DURATION=0
WARN_MSGS=""

# ---------------------------------------------------------------------------
# FUNCTIONS
# ---------------------------------------------------------------------------

log() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

log_section() {
    log "-----------------------------------------------------------"
    log " $*"
    log "-----------------------------------------------------------"
}

# Run a dsmadmc command; echo output; return exit code
tsm() {
    "$DSMADMC" -se="$TSM_SERVER" \
               -id="$TSM_ADMIN_ID" \
               -pa="$TSM_ADMIN_PW" \
               -dataonly=yes \
               -comma \
               "$@" 2>&1
}

# Send email via sendmail
send_email() {
    local subject="$1"
    local body="$2"
    {
        printf "From: %s\n"    "$EMAIL_FROM"
        printf "To: %s\n"      "$EMAIL_TO"
        printf "Subject: %s\n" "$subject"
        printf "Content-Type: text/plain; charset=UTF-8\n"
        printf "\n"
        printf "%s\n" "$body"
    } | "$SENDMAIL" -t 2>>"$LOG_FILE"
    log "Email dispatched to $EMAIL_TO  |  Subject: $subject"
}

# Clean up files older than N days inside $TEMP_DIR
rotate_temp() {
    local deleted
    deleted=$(find "$TEMP_DIR" -maxdepth 1 -type f -mtime +"$TEMP_KEEP_DAYS" 2>/dev/null)
    if [ -n "$deleted" ]; then
        echo "$deleted" | while IFS= read -r f; do
            rm -f "$f" && log "Rotated (deleted): $f"
        done
    else
        log "No files older than $TEMP_KEEP_DAYS days to rotate in $TEMP_DIR"
    fi
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
log_section "START  $SCRIPT_NAME  $(date)"
SCRIPT_START_TS=$(date +%s)

# ===========================================================================
# STEP 1 – Check scratch volume availability
# ===========================================================================
log_section "STEP 1: Check scratch volume availability"

SCRATCH_OUT=$(tsm "query libvolume $TSM_LIBRARY status=scratch")
log "$SCRATCH_OUT"
SCRATCH_COUNT=$(echo "$SCRATCH_OUT" | grep -ci "scratch" 2>/dev/null || echo 0)
log "Scratch volumes found: $SCRATCH_COUNT"

if [ "$SCRATCH_COUNT" -lt 1 ]; then
    OVERALL_STATUS="WARNING"
    WARN_MSGS="No scratch volumes available in library $TSM_LIBRARY on server $TSM_SERVER."
    log "WARNING: $WARN_MSGS"

    EMAIL_SUBJECT="[WARNING] TSM DR Backup - No Scratch Tapes - $(date '+%Y-%m-%d')"
    EMAIL_BODY="WARNING: TSM DRM Backup - Scratch Volumes NOT Available
==============================================================
Date   : $(date)
Server : $TSM_SERVER
Library: $TSM_LIBRARY

No scratch tapes were found in library $TSM_LIBRARY.
Please load scratch tapes into the library IO station and retry.

The TSM DB backup was NOT started.

Log file: $LOG_FILE

-- Automated message from $SCRIPT_NAME --"

    send_email "$EMAIL_SUBJECT" "$EMAIL_BODY"
    log "Script exiting with WARNING (no scratch tapes)."
    exit 1
fi

# ===========================================================================
# STEP 2 – Reclaim VaultRetrieve tapes  →  move to Onsite  →  checkin Scratch
# ===========================================================================
log_section "STEP 2: Process VaultRetrieve tapes"

VR_OUT=$(tsm "query drmedia * wherest=vaultretrieve")
log "VaultRetrieve query output:"
log "$VR_OUT"

# Extract volume names (first field, skip header lines)
VR_TAPES=$(echo "$VR_OUT" | awk -F',' 'NR>1 && $1 ~ /^[A-Z0-9]/{print $1}' | tr -d ' ')

if [ -z "$VR_TAPES" ]; then
    log "No tapes in VaultRetrieve state. Skipping reclaim step."
else
    log "Tapes to reclaim: $(echo "$VR_TAPES" | tr '\n' ' ')"
    for TAPE in $VR_TAPES; do
        log "  Moving $TAPE  VaultRetrieve → Onsite ..."
        MOVE_OUT=$(tsm "move drmedia $TAPE wherest=vaultretrieve tost=onsite")
        log "  $MOVE_OUT"
        TAPE_RECLAIMED="${TAPE_RECLAIMED} ${TAPE}"
    done

    log "Checking reclaimed tapes back into library as Scratch (bulk/barcode) ..."
    CHECKIN_OUT=$(tsm "checkin libvolume $TSM_LIBRARY search=bulk status=scratch checkl=barcode waitt=0")
    log "$CHECKIN_OUT"
fi

# ===========================================================================
# STEP 3 – Delete expired volume history (DB backup volumes older than 3 days)
# ===========================================================================
log_section "STEP 3: Delete expired volume history (>$TSM_RETENTION_DAYS days)"

EXPIRE_DATE=$(date -d "-${TSM_RETENTION_DAYS} days" '+%m/%d/%Y' 2>/dev/null || \
              /usr/bin/perl -e 'use POSIX;printf "%02d/%02d/%04d\n",(localtime(time-'"$TSM_RETENTION_DAYS"'*86400))[4]+1,(localtime(time-'"$TSM_RETENTION_DAYS"'*86400))[3],(localtime(time-'"$TSM_RETENTION_DAYS"'*86400))[5]+1900' 2>/dev/null)

log "Deleting DBB volhist entries on or before: $EXPIRE_DATE"
DELVH_OUT=$(tsm "delete volhist type=dbb todate=$EXPIRE_DATE")
log "$DELVH_OUT"

# ===========================================================================
# STEP 4 – Run TSM DB Full Backup
# ===========================================================================
log_section "STEP 4: TSM DB Full Backup  (type=full devc=$TSM_DEVCLASS)"

T1=$(date +%s)
BACKUP_OUT=$(tsm "backup db type=full devc=$TSM_DEVCLASS")
BACKUP_RC=$?
T2=$(date +%s)
BACKUP_DURATION=$(( T2 - T1 ))

log "Backup output:"
log "$BACKUP_OUT"
log "Backup return code: $BACKUP_RC  |  Duration: ${BACKUP_DURATION}s"

# Check for error messages in output
if echo "$BACKUP_OUT" | grep -qiE "ANS[0-9]+E|error|fail"; then
    OVERALL_STATUS="ERROR"
    log "ERROR: TSM DB backup reported errors!"

    EMAIL_SUBJECT="[ERROR] TSM DR DB Backup FAILED - $(date '+%Y-%m-%d')"
    EMAIL_BODY="ERROR: TSM DRM DB Backup FAILED on server $TSM_SERVER
==============================================================
Date    : $(date)
Server  : $TSM_SERVER
DevClass: $TSM_DEVCLASS
Duration: ${BACKUP_DURATION}s

Backup Output:
$BACKUP_OUT

Please investigate immediately.
Log file: $LOG_FILE

-- Automated message from $SCRIPT_NAME --"

    send_email "$EMAIL_SUBJECT" "$EMAIL_BODY"
    log "Error email sent. Exiting."
    exit 2
fi

# Extract volume name used for this backup
BACKUP_VOL=$(echo "$BACKUP_OUT" | grep -i "volume" | awk '{print $NF}' | head -1)
log "Backup completed OK  |  Volume: ${BACKUP_VOL:-unknown}"

# ===========================================================================
# STEP 5 – Run PREPARE (generates disaster recovery files)
# ===========================================================================
log_section "STEP 5: Run PREPARE (generate DR recovery files)"

PREPARE_OUT=$(tsm "prepare stgpools=yes")
log "$PREPARE_OUT"

# TSM writes the prepare file with timestamp name (e.g. 20260516.190032)
# into the TSM instance home directory
PREPARE_FILE=$(ls -t "${TSM_INST_HOME}"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].[0-9][0-9][0-9][0-9][0-9][0-9] 2>/dev/null | head -1)
log "Latest prepare file: ${PREPARE_FILE:-not found}"

# ===========================================================================
# STEP 6 – Copy files to /temp with 7-day rotation
# ===========================================================================
log_section "STEP 6: Copy DR files to $TEMP_DIR"

DATE_TAG=$(date '+%Y%m%d_%H%M%S')
COPIED_FILES=""

# volhist.dat
VOLHIST_SRC="${TSM_INST_HOME}/volhist.dat"
if [ -f "$VOLHIST_SRC" ]; then
    cp "$VOLHIST_SRC" "${TEMP_DIR}/volhist_${DATE_TAG}.dat" && \
        log "Copied: volhist.dat → ${TEMP_DIR}/volhist_${DATE_TAG}.dat" && \
        COPIED_FILES="${COPIED_FILES}\n  volhist_${DATE_TAG}.dat"
else
    log "WARNING: $VOLHIST_SRC not found – skipping"
    WARN_MSGS="${WARN_MSGS}\nvolhist.dat not found at $VOLHIST_SRC"
fi

# devconf.dat
DEVCONF_SRC="${TSM_INST_HOME}/devconf.dat"
if [ -f "$DEVCONF_SRC" ]; then
    cp "$DEVCONF_SRC" "${TEMP_DIR}/devconf_${DATE_TAG}.dat" && \
        log "Copied: devconf.dat → ${TEMP_DIR}/devconf_${DATE_TAG}.dat" && \
        COPIED_FILES="${COPIED_FILES}\n  devconf_${DATE_TAG}.dat"
else
    log "WARNING: $DEVCONF_SRC not found – skipping"
    WARN_MSGS="${WARN_MSGS}\ndevconf.dat not found at $DEVCONF_SRC"
fi

# prepare file  (timestamped name like 20260516.190032)
if [ -n "$PREPARE_FILE" ] && [ -f "$PREPARE_FILE" ]; then
    PREPARE_BASENAME=$(basename "$PREPARE_FILE")
    cp "$PREPARE_FILE" "${TEMP_DIR}/${PREPARE_BASENAME}_${DATE_TAG}" && \
        log "Copied: $PREPARE_BASENAME → ${TEMP_DIR}/${PREPARE_BASENAME}_${DATE_TAG}" && \
        COPIED_FILES="${COPIED_FILES}\n  ${PREPARE_BASENAME}_${DATE_TAG}"
else
    log "WARNING: Prepare file not found – skipping"
    WARN_MSGS="${WARN_MSGS}\nPrepare file not generated/found"
fi

# Rotate files older than 7 days
rotate_temp

# ===========================================================================
# STEP 7 – Send SUCCESS email
# ===========================================================================
log_section "STEP 7: Send notification email"

SCRIPT_END_TS=$(date +%s)
TOTAL_DURATION=$(( SCRIPT_END_TS - SCRIPT_START_TS ))

WARN_SECTION=""
[ -n "$WARN_MSGS" ] && WARN_SECTION="
WARNINGS:
$(echo "$WARN_MSGS" | sed 's/^/  /')
"

EMAIL_SUBJECT="[SUCCESS] TSM DR DRM Backup Completed - $(date '+%Y-%m-%d')"
EMAIL_BODY="TSM DRM Daily Backup completed SUCCESSFULLY on server $TSM_SERVER
==============================================================
Date          : $(date)
Server        : $TSM_SERVER
Device Class  : $TSM_DEVCLASS
Library       : $TSM_LIBRARY
Scratch Tapes : $SCRATCH_COUNT available

BACKUP SUMMARY
--------------
Backup Volume : ${BACKUP_VOL:-see log}
Backup Time   : ${BACKUP_DURATION}s
Total Runtime : ${TOTAL_DURATION}s

TAPE RECLAIM (VaultRetrieve → Onsite → Scratch)
-------------------------------------------------
Tapes reclaimed : ${TAPE_RECLAIMED:- none today}

VOLUME HISTORY CLEANUP
-----------------------
Deleted DBB entries older than: $EXPIRE_DATE  ($TSM_RETENTION_DAYS day retention)

FILES COPIED TO $TEMP_DIR  (7-day rotation active)
$(echo "$COPIED_FILES")
$WARN_SECTION
Log file: $LOG_FILE

-- Automated message from $SCRIPT_NAME --"

send_email "$EMAIL_SUBJECT" "$EMAIL_BODY"

log_section "COMPLETED  $SCRIPT_NAME  $(date)  |  Total: ${TOTAL_DURATION}s  |  Status: $OVERALL_STATUS"
exit 0
