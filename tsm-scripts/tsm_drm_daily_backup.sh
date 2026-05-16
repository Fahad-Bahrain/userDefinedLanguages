#!/bin/ksh
# =============================================================================
#  TSM DRM Daily Backup Automation Script
#  Server  : DR-EKKERP80  (IBM AIX 7.2, TSM 8.1)
#  Instance: tsminst2
#  Schedule: Daily 7:00 PM via cron
#
#  Flow:
#   1. Check scratch tape availability in LTO6 library
#   2. Reclaim VaultRetrieve tapes → move to Onsite → checkin as Scratch
#   3. Delete expired volume history  (DBB entries older than 3 days)
#   4. Run TSM DB full backup         (backup db type=full devc=ltoclass6)
#   5. Run PREPARE                    (generates disaster recovery files)
#   6. Copy volhist.dat / devconf.dat / prepare-file to /temp (7-day rotation)
#   7. Send email  →  SUCCESS  |  WARNING (no scratch)  |  ERROR (backup failed)
#
#  AIX 7.2 compatibility: uses ksh93 typeset, Perl for date math,
#  egrep for extended regex, find without -maxdepth/-delete.
# =============================================================================

# ---------------------------------------------------------------------------
# CONFIGURATION  –  edit only this section if paths change
# ---------------------------------------------------------------------------
TSM_SERVER="DR-EKKERP80"
TSM_ADMIN_ID="admin"
TSM_ADMIN_PW="admin123"
TSM_LIBRARY="LTO6"
TSM_DEVCLASS="ltoclass6"
TSM_RETENTION_DAYS=3       # DB backup tapes expire after N days
TEMP_DIR="/home/tsminst2/temp"   # tsminst2 owns this; no root needed
TEMP_KEEP_DAYS=7                 # keep files in temp dir for N days then delete

# TSM instance home – volhist.dat, devconf.dat and prepare files live here
TSM_INST_HOME="/home/tsminst2"

EMAIL_TO="mohammed.fahad@ekkanoo.com.bh"
EMAIL_FROM="tsm-drm@ekkerp80"

SCRIPT_NAME="TSM_DRM_Backup"
LOG_DIR="/home/tsminst2/logs"
LOG_FILE="${LOG_DIR}/tsm_drm_$(date +%Y%m%d_%H%M%S).log"

# ---------------------------------------------------------------------------
# PATH – ensure TSM binaries are reachable from cron environment
# ---------------------------------------------------------------------------
export PATH=/usr/bin:/usr/sbin:/usr/local/bin:/opt/tivoli/tsm/client/ba/bin:$PATH

# Locate dsmadmc (AIX TSM 8.1 – usually in PATH for tsminst2)
DSMADMC=$(whence dsmadmc 2>/dev/null)
if [ -z "$DSMADMC" ]; then
    # common fallback locations on AIX
    for _p in /usr/bin/dsmadmc \
               /opt/tivoli/tsm/client/ba/bin/dsmadmc \
               /usr/tivoli/tsm/client/ba/bin/dsmadmc; do
        [ -x "$_p" ] && { DSMADMC="$_p"; break; }
    done
fi

# Locate sendmail (AIX uses /usr/lib/sendmail)
SENDMAIL=""
for _s in /usr/lib/sendmail /usr/sbin/sendmail /usr/bin/sendmail; do
    [ -x "$_s" ] && { SENDMAIL="$_s"; break; }
done

# ---------------------------------------------------------------------------
# INIT
# ---------------------------------------------------------------------------
mkdir -p "$LOG_DIR" "$TEMP_DIR"

OVERALL_STATUS="SUCCESS"
TAPE_RECLAIMED=""
BACKUP_VOL=""
BACKUP_DURATION=0
WARN_MSGS=""
COPIED_FILES=""

# ---------------------------------------------------------------------------
# FUNCTIONS
# ---------------------------------------------------------------------------

log() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

log_section() {
    log "============================================================"
    log "  $*"
    log "============================================================"
}

# tsm <command>  –  run a dsmadmc command and return its output
tsm() {
    if [ -z "$DSMADMC" ]; then
        log "ERROR: dsmadmc not found in PATH or known locations."
        exit 9
    fi
    "$DSMADMC" -se="$TSM_SERVER" \
               -id="$TSM_ADMIN_ID" \
               -pa="$TSM_ADMIN_PW" \
               -dataonly=yes \
               -comma \
               "$@" 2>&1
}

# send_email <subject> <body>
send_email() {
    typeset subject="$1"
    typeset body="$2"

    if [ -z "$SENDMAIL" ]; then
        log "WARNING: sendmail not found – cannot send email."
        return 1
    fi

    {
        printf "From: %s\n"    "$EMAIL_FROM"
        printf "To: %s\n"      "$EMAIL_TO"
        printf "Subject: %s\n" "$subject"
        printf "MIME-Version: 1.0\n"
        printf "Content-Type: text/plain; charset=UTF-8\n"
        printf "\n"
        printf "%s\n" "$body"
    } | "$SENDMAIL" -t 2>>"$LOG_FILE"

    log "Email dispatched  →  $EMAIL_TO"
    log "Subject: $subject"
}

# aix_date_offset <days>  –  returns date N days in the past as MM/DD/YYYY
# Uses Perl because AIX date does not support -d flag
aix_date_offset() {
    typeset days="$1"
    perl -e "
        use POSIX qw(strftime);
        my \$t = time() - ($days * 86400);
        my (\$d,\$m,\$y) = (localtime(\$t))[3,4,5];
        printf \"%02d/%02d/%04d\n\", \$m+1, \$d, \$y+1900;
    " 2>/dev/null
}

# rotate_temp  –  delete files in TEMP_DIR older than TEMP_KEEP_DAYS days
# Uses find without -maxdepth and without -delete (AIX compatible)
rotate_temp() {
    typeset f
    find "$TEMP_DIR" -type f -mtime +"$TEMP_KEEP_DAYS" | while read f; do
        rm -f "$f" && log "Rotated (deleted): $f"
    done
    log "Rotation complete. Files newer than $TEMP_KEEP_DAYS days retained."
}

# copy_file <src> <dest_name_suffix>  –  copy file to TEMP_DIR with date tag
copy_to_temp() {
    typeset src="$1"
    typeset tag="$2"
    typeset base dest
    base=$(basename "$src")
    dest="${TEMP_DIR}/${base}_${tag}"

    if [ -f "$src" ]; then
        cp "$src" "$dest" && log "Copied: $src  →  $dest" \
            && COPIED_FILES="${COPIED_FILES}  $dest\n"
    else
        log "WARNING: $src not found – skipping copy"
        WARN_MSGS="${WARN_MSGS}  - $src not found\n"
    fi
}

# ---------------------------------------------------------------------------
# PRE-FLIGHT CHECK
# ---------------------------------------------------------------------------
log_section "START  $SCRIPT_NAME  $(date)"
log "dsmadmc  : ${DSMADMC:-NOT FOUND}"
log "sendmail : ${SENDMAIL:-NOT FOUND}"
log "LOG      : $LOG_FILE"

[ -z "$DSMADMC" ] && { log "FATAL: dsmadmc not found. Aborting."; exit 9; }

SCRIPT_START_TS=$(date +%s)

# ===========================================================================
# STEP 1  –  Check scratch volume availability in LTO6
# ===========================================================================
log_section "STEP 1: Check scratch volume availability  ($TSM_LIBRARY)"

SCRATCH_OUT=$(tsm "query libvolume $TSM_LIBRARY")
log "$SCRATCH_OUT"

# count lines that contain actual volume entries (not header/blank)
SCRATCH_COUNT=$(echo "$SCRATCH_OUT" | grep -c "Scratch" 2>/dev/null)
[ -z "$SCRATCH_COUNT" ] && SCRATCH_COUNT=0
log "Scratch volumes found: $SCRATCH_COUNT"

if [ "$SCRATCH_COUNT" -lt 1 ]; then
    OVERALL_STATUS="WARNING"
    log "WARNING: No scratch volumes in $TSM_LIBRARY – backup cannot proceed."

    send_email \
        "[WARNING] TSM DR Backup - No Scratch Tapes Available - $(date '+%Y-%m-%d')" \
"WARNING: TSM DRM Backup – Scratch Volumes NOT Available
==============================================================
Date   : $(date)
Server : $TSM_SERVER
Library: $TSM_LIBRARY

No scratch tapes were found in library $TSM_LIBRARY.
Please load scratch tapes into the library IO station.

The TSM DB backup was NOT started.

Log file: $LOG_FILE

-- Automated message from $SCRIPT_NAME on $(hostname) --"

    exit 1
fi

# ===========================================================================
# STEP 2  –  Process VaultRetrieve tapes  →  Onsite  →  Scratch
# ===========================================================================
log_section "STEP 2: Reclaim VaultRetrieve tapes"

VR_OUT=$(tsm "query drmedia * wherest=vaultretrieve")
log "VaultRetrieve query:"
log "$VR_OUT"

# Extract volume names from comma-separated dsmadmc output
# First field of each data row, skip header and blank lines
# Only parse volume names if query succeeded (no ANR2034E "no match" error)
if echo "$VR_OUT" | grep -q "ANR2034E"; then
    VR_TAPES=""
else
    VR_TAPES=$(echo "$VR_OUT" | awk -F',' 'NR>1 && $1 ~ /^[A-Z0-9]/ {gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}')
fi

if [ -z "$VR_TAPES" ]; then
    log "No tapes in VaultRetrieve state today – skipping reclaim step."
else
    log "Tapes to reclaim: $(echo "$VR_TAPES" | tr '\n' ' ')"

    echo "$VR_TAPES" | while read TAPE; do
        [ -z "$TAPE" ] && continue
        log "  Moving $TAPE  VaultRetrieve -> Onsite ..."
        MOVE_OUT=$(tsm "move drmedia $TAPE wherest=vaultretrieve tost=onsite")
        log "  $MOVE_OUT"
        TAPE_RECLAIMED="${TAPE_RECLAIMED} ${TAPE}"
    done

    log "Checking reclaimed tapes back into $TSM_LIBRARY as Scratch (bulk / barcode) ..."
    CHECKIN_OUT=$(tsm "checkin libvolume $TSM_LIBRARY search=bulk status=scratch checkl=barcode waitt=0")
    log "$CHECKIN_OUT"
fi

# ===========================================================================
# STEP 3  –  Delete expired volume history  (DBB older than retention days)
# ===========================================================================
log_section "STEP 3: Delete expired volume history  (>${TSM_RETENTION_DAYS} days)"

EXPIRE_DATE=$(aix_date_offset "$TSM_RETENTION_DAYS")

if [ -z "$EXPIRE_DATE" ]; then
    log "WARNING: Could not calculate expiry date (Perl missing?). Skipping delete volhist."
    WARN_MSGS="${WARN_MSGS}  - delete volhist skipped: date calculation failed\n"
else
    log "Deleting DBB volhist entries on or before: $EXPIRE_DATE"
    DELVH_OUT=$(tsm "delete volhist type=dbb todate=$EXPIRE_DATE")
    log "$DELVH_OUT"
fi

# ===========================================================================
# STEP 4  –  TSM DB Full Backup  (waits for completion before proceeding)
# ===========================================================================
log_section "STEP 4: TSM DB Full Backup  (type=full  devc=$TSM_DEVCLASS)"

T1=$(date +%s)
BACKUP_OUT=$(tsm "backup db type=full devc=$TSM_DEVCLASS")
log "Backup submit output:"
log "$BACKUP_OUT"

# Check for immediate hard errors (e.g. already in progress, no device class)
if echo "$BACKUP_OUT" | egrep -qi "ANR[0-9]+E|ANS[0-9]+E"; then
    if echo "$BACKUP_OUT" | grep -q "ANR2433E"; then
        # Another backup already running – treat as warning, not fatal
        log "WARNING: Another backup is already in progress (ANR2433E). Will wait for it."
        WARN_MSGS="${WARN_MSGS}  - backup was already in progress when script ran\n"
    else
        # Real error – fail immediately
        T2=$(date +%s)
        BACKUP_DURATION=$(( T2 - T1 ))
        OVERALL_STATUS="ERROR"
        log "ERROR: TSM DB backup failed to start!"
        send_email \
            "[ERROR] TSM DR DB Backup FAILED - $(date '+%Y-%m-%d')" \
"ERROR: TSM DRM DB Backup FAILED to start on $TSM_SERVER
==============================================================
Date    : $(date)
Server  : $TSM_SERVER
DevClass: $TSM_DEVCLASS
Library : $TSM_LIBRARY

--- Output ---
$BACKUP_OUT

Please investigate immediately.
Log file: $LOG_FILE

-- Automated message from $SCRIPT_NAME on $(hostname) --"
        exit 2
    fi
fi

# Extract process number from output
# "ANS8003I Process number 32 started."  →  field 4 is the number
PROC_NUM=$(echo "$BACKUP_OUT" | grep "ANS8003I" | awk '{print $4}')

# If ANR2433E (already running), find the existing DB backup process number
if [ -z "$PROC_NUM" ]; then
    log "Querying active processes to find existing DB backup ..."
    ALL_PROCS=$(tsm "query process")
    log "$ALL_PROCS"
    PROC_NUM=$(echo "$ALL_PROCS" | grep -i "Database Backup" | awk '{print $1}' | head -1)
fi

log "Backup process number: ${PROC_NUM:-unknown}"

# ---- Wait for backup process to finish (poll every 60 seconds) ----
if [ -n "$PROC_NUM" ]; then
    log "Waiting for backup process $PROC_NUM to complete (checking every 60s) ..."
    WAIT_MIN=0
    while true; do
        sleep 60
        WAIT_MIN=$(( WAIT_MIN + 1 ))
        PROC_CHECK=$(tsm "query process $PROC_NUM")
        if echo "$PROC_CHECK" | grep -qi "Database Backup"; then
            PROGRESS=$(echo "$PROC_CHECK" | grep -i "Bytes backed up" | awk -F: '{print $2}' | tr -d ' \n')
            log "  [${WAIT_MIN} min] In progress – Bytes backed up: ${PROGRESS:-0}"
        else
            log "  [${WAIT_MIN} min] Process $PROC_NUM no longer active – backup finished."
            break
        fi
        # Safety timeout: 8 hours
        if [ "$WAIT_MIN" -gt 480 ]; then
            log "WARNING: Backup wait timeout after 8 hours."
            WARN_MSGS="${WARN_MSGS}  - backup process timed out after 8 hours\n"
            break
        fi
    done
else
    log "WARNING: No active DB backup process found – cannot wait for completion."
    WARN_MSGS="${WARN_MSGS}  - backup process number unknown; result not confirmed\n"
fi

T2=$(date +%s)
BACKUP_DURATION=$(( T2 - T1 ))
log "Backup duration: ${BACKUP_DURATION}s  ($(( BACKUP_DURATION / 60 )) min)"

# Verify result from activity log
log "Checking activity log for backup result ..."
TODAY_DATE=$(date '+%m/%d/%Y')
ACT_OUT=$(tsm "query actlog begindate=$TODAY_DATE search=ANR2280")
log "$ACT_OUT"
if echo "$ACT_OUT" | grep -qi "ANR2284I\|successfully completed\|ANR2280I"; then
    BACKUP_VOL=$(echo "$ACT_OUT" | grep -i "volume" | awk '{print $NF}' | tail -1)
    log "Backup confirmed successful in activity log."
elif echo "$ACT_OUT" | egrep -qi "ANR[0-9]+E|fail"; then
    OVERALL_STATUS="ERROR"
    log "ERROR: Activity log shows backup failure!"
    send_email \
        "[ERROR] TSM DR DB Backup FAILED - $(date '+%Y-%m-%d')" \
"ERROR: TSM DRM DB Backup FAILED on $TSM_SERVER
==============================================================
Date    : $(date)
Server  : $TSM_SERVER
DevClass: $TSM_DEVCLASS
Duration: ${BACKUP_DURATION}s  ($(( BACKUP_DURATION / 60 )) min)

--- Activity Log ---
$ACT_OUT

Log file: $LOG_FILE

-- Automated message from $SCRIPT_NAME on $(hostname) --"
    exit 2
fi

# Extract volume name used for this backup (last token from line containing Volume)
BACKUP_VOL=$(echo "$BACKUP_OUT" | grep -i "volume" | awk '{print $NF}' | head -1)
log "Backup completed OK  |  Volume used: ${BACKUP_VOL:-see log}"

# ===========================================================================
# STEP 5  –  Run PREPARE  (generates DR recovery files)
# ===========================================================================
log_section "STEP 5: Run PREPARE  (generate disaster recovery files)"

PREPARE_OUT=$(tsm "prepare")
log "$PREPARE_OUT"

# TSM writes the prepare file with a timestamp name (e.g. 20260516.190032)
# into the TSM instance home directory – pick the newest one
PREPARE_FILE=$(ls -t "${TSM_INST_HOME}"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].[0-9][0-9][0-9][0-9][0-9][0-9] 2>/dev/null | head -1)
log "Prepare file: ${PREPARE_FILE:-not found}"

# ===========================================================================
# STEP 6  –  Copy 3 DR files to /temp  +  7-day rotation
# ===========================================================================
log_section "STEP 6: Copy DR files to $TEMP_DIR  (7-day rotation)"

DATE_TAG=$(date '+%Y%m%d_%H%M%S')

copy_to_temp "${TSM_INST_HOME}/volhist.dat"  "$DATE_TAG"
copy_to_temp "${TSM_INST_HOME}/devconf.dat"  "$DATE_TAG"

if [ -n "$PREPARE_FILE" ] && [ -f "$PREPARE_FILE" ]; then
    copy_to_temp "$PREPARE_FILE" "$DATE_TAG"
else
    log "WARNING: Prepare file not found – skipping copy"
    WARN_MSGS="${WARN_MSGS}  - prepare file not found\n"
fi

log "Running 7-day rotation in $TEMP_DIR ..."
rotate_temp

# ===========================================================================
# STEP 7  –  Send SUCCESS email
# ===========================================================================
log_section "STEP 7: Send SUCCESS notification"

SCRIPT_END_TS=$(date +%s)
TOTAL_DURATION=$(( SCRIPT_END_TS - SCRIPT_START_TS ))

WARN_BLOCK=""
[ -n "$WARN_MSGS" ] && WARN_BLOCK="
WARNINGS DURING RUN:
$(printf '%b' "$WARN_MSGS")
"

send_email \
    "[SUCCESS] TSM DR DRM Backup Completed - $(date '+%Y-%m-%d')" \
"TSM DRM Daily Backup completed SUCCESSFULLY on $TSM_SERVER
==============================================================
Date          : $(date)
Server        : $TSM_SERVER
Device Class  : $TSM_DEVCLASS
Library       : $TSM_LIBRARY
Scratch Tapes : $SCRATCH_COUNT available before backup

BACKUP SUMMARY
--------------
Volume Used   : ${BACKUP_VOL:-see log}
Backup Time   : ${BACKUP_DURATION}s
Total Runtime : ${TOTAL_DURATION}s

TAPE RECLAIM  (VaultRetrieve -> Onsite -> Scratch)
---------------------------------------------------
Tapes reclaimed : ${TAPE_RECLAIMED:- none today}

VOLUME HISTORY CLEANUP
----------------------
Deleted DBB entries on/before : ${EXPIRE_DATE:-skipped}
Retention policy              : ${TSM_RETENTION_DAYS} days

FILES COPIED TO $TEMP_DIR  (7-day rotation active)
$(printf '%b' "$COPIED_FILES")
$WARN_BLOCK
Log file: $LOG_FILE

-- Automated message from $SCRIPT_NAME on $(hostname) --"

log_section "COMPLETED  $SCRIPT_NAME  |  $(date)  |  Status: $OVERALL_STATUS  |  ${TOTAL_DURATION}s"
exit 0
