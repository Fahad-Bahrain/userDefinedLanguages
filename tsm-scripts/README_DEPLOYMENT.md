# TSM DRM Daily Backup – Deployment Guide
**Server:** DR-EKKERP80 | **OS User:** tsminst2 | **Schedule:** 19:00 daily

---

## What the Script Does (in order)

| Step | Action | TSM Command |
|------|--------|-------------|
| 1 | Check scratch tape count in LTO6 | `query libvolume LTO6 status=scratch` |
| 2 | Move VaultRetrieve tapes → Onsite | `move drmedia * wherest=vaultretrieve tost=onsite` |
| 2 | Check reclaimed tapes in as Scratch | `checkin libvolume LTO6 search=bulk status=scratch checkl=barcode waitt=0` |
| 3 | Delete DBB volhist older than 3 days | `delete volhist type=dbb todate=<3-days-ago>` |
| 4 | Full TSM DB backup | `backup db type=full devc=ltoclass6` |
| 5 | Generate DR recovery files | `prepare stgpools=yes` |
| 6 | Copy 3 files to /temp (7-day rotation) | volhist.dat, devconf.dat, prepare file |
| 7 | Send email | SUCCESS / WARNING / ERROR |

---

## One-Time Deployment Steps

### 1. Transfer files to DR-EKKERP80
```sh
# From your workstation or jump host:
scp tsm_drm_daily_backup.sh tsminst2@ekkerp80:/home/tsminst2/scripts/
scp setup_cron.sh            tsminst2@ekkerp80:/home/tsminst2/scripts/
```

### 2. SSH into DR-EKKERP80 as tsminst2
```sh
ssh tsminst2@ekkerp80
```

### 3. Run the setup script
```sh
chmod +x /home/tsminst2/scripts/setup_cron.sh
/home/tsminst2/scripts/setup_cron.sh
```

This installs the cron entry: **`0 19 * * *`** (every day at 19:00)

### 4. Verify cron
```sh
crontab -l
# Expected output:
# 0 19 * * * /home/tsminst2/scripts/tsm_drm_daily_backup.sh >> /home/tsminst2/logs/cron_drm.log 2>&1
```

### 5. Test run manually
```sh
/home/tsminst2/scripts/tsm_drm_daily_backup.sh
tail -f /home/tsminst2/logs/tsm_drm_*.log
```

---

## Email Notifications

| Status | Subject | Trigger |
|--------|---------|---------|
| WARNING | `[WARNING] TSM DR Backup - No Scratch Tapes` | Zero scratch tapes found → backup skipped |
| ERROR | `[ERROR] TSM DR DB Backup FAILED` | Backup ran but TSM reported error |
| SUCCESS | `[SUCCESS] TSM DR DRM Backup Completed` | All steps completed OK |

Emails go to: **mohammed.fahad@ekkanoo.com.bh**

---

## Key Paths

| Item | Path |
|------|------|
| Script | `/home/tsminst2/scripts/tsm_drm_daily_backup.sh` |
| Daily logs | `/home/tsminst2/logs/tsm_drm_YYYYMMDD_HHMMSS.log` |
| Cron output | `/home/tsminst2/logs/cron_drm.log` |
| Rotated DR files | `/temp/volhist_*.dat`, `/temp/devconf_*.dat`, `/temp/YYYYMMDD.HHMMSS_*` |
| TSM instance home | `/home/tsminst2` |

---

## Tape Retention Policy

```
Backup runs daily at 19:00
↓
Tape used for backup  →  DRM state: Mountable
↓  (after 3 days)
DRM state transitions to: VaultRetrieve
↓  (next script run)
move drmedia  VaultRetrieve → Onsite
checkin libvolume  status=scratch
↓
Tape available again for next backup
```

---

## Troubleshooting

**No scratch tapes warning every day?**
→ Check tapes are physically in the IO station of the LTO6 library.
→ Run manually: `checkin libvolume LTO6 search=bulk status=scratch checkl=barcode waitt=0`

**Backup fails with ANS error?**
→ Check log at `/home/tsminst2/logs/tsm_drm_*.log`
→ Verify device class: `query devclass ltoclass6`

**prepare file not found?**
→ Confirm TSM instance home path is `/home/tsminst2` in the script config section.
→ Check: `ls /home/tsminst2/[0-9]*.* 2>/dev/null`

**Email not received?**
→ Confirm sendmail is running: `ps -ef | grep sendmail`
→ Check: `/var/mail/tsminst2` for bounces
