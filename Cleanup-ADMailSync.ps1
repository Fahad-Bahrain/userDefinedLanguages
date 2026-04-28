<#
.SYNOPSIS
    Cleans up C:\AD-MailSync\ by archiving backups, build artefacts,
    duplicate scripts and old output CSVs.
    Nothing is permanently deleted — everything goes to _archive\.
#>

$root    = "C:\AD-MailSync"
$archive = Join-Path $root "_archive"

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  AD-MailSync  Cleanup  (safe archive mode)"          -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

# ── helper ───────────────────────────────────────────────────────────────────
function Move-ToArchive {
    param([string]$src, [string]$subDir = "")
    if (-not (Test-Path $src)) { return }
    $dest = if ($subDir) { Join-Path $archive $subDir } else { $archive }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $name = Split-Path $src -Leaf
    $target = Join-Path $dest $name
    # avoid collision
    if (Test-Path $target) {
        $target = Join-Path $dest ("{0}_{1}" -f [System.IO.Path]::GetFileNameWithoutExtension($name),
            (Get-Date -Format 'HHmmss') + [System.IO.Path]::GetExtension($name))
    }
    Move-Item -Path $src -Destination $target -Force
    Write-Host "  [MOVED] $src" -ForegroundColor DarkGray
}

New-Item -ItemType Directory -Path $archive -Force | Out-Null

# ── 1. Entire folders that are clearly old ────────────────────────────────────
Write-Host "1) Archiving old folders (backup, New folder, build, dist)..." -ForegroundColor Yellow
foreach ($folder in @("backup", "New folder", "build", "dist")) {
    $p = Join-Path $root $folder
    if (Test-Path $p) {
        Move-ToArchive $p
    }
}

# ── 2. Duplicate / temp root files ───────────────────────────────────────────
Write-Host "2) Archiving duplicate/temp files in root..." -ForegroundColor Yellow
$rootJunk = @(
    "README.txt.txt",      # duplicate README
    "script_silent.txt"    # old notes
)
foreach ($f in $rootJunk) {
    Move-ToArchive (Join-Path $root $f) "root_misc"
}

# ── 3. Duplicate root-level scripts ──────────────────────────────────────────
# Active script: AD-MailSync.ps1  (called by AD-MailSync_PS1_wrapper.cmd)
# Keep:  AD-MailSync.ps1, ad-sync_silent_PATCHED.ps1 (largest/newest)
# Archive: older variants
Write-Host "3) Archiving older script variants..." -ForegroundColor Yellow
$oldScripts = @(
    "AD-MailSync_AllEKKEmployees.ps1",     # superseded by _v2
    "AD-MailSync_AllEKKEmployees_v2.ps1",  # dev variant; AD-MailSync.ps1 is the live one
    "ad-sync_silent.ps1"                   # original; PATCHED version is newer
)
foreach ($f in $oldScripts) {
    Move-ToArchive (Join-Path $root $f) "old_scripts"
}

# ── 4. output\ — keep only the LATEST file of each report type ───────────────
Write-Host "4) Pruning output\ CSVs (keeping latest of each type)..." -ForegroundColor Yellow
$outDir = Join-Path $root "output"
if (Test-Path $outDir) {
    # group by report prefix (everything before the timestamp _YYYYMMDD-)
    $groups = Get-ChildItem $outDir -Filter "*.csv" |
        Group-Object { ($_.Name -replace '_\d{8}-\d{4}.*', '').ToLower() }

    foreach ($g in $groups) {
        $sorted  = $g.Group | Sort-Object LastWriteTime -Descending
        $keep    = $sorted[0]
        $discard = $sorted | Select-Object -Skip 1
        Write-Host "    Keep : $($keep.Name)" -ForegroundColor Green
        foreach ($old in $discard) {
            Move-ToArchive $old.FullName "output_old"
        }
    }
}

# ── 5. Logs\ — keep last 10, archive the rest ─────────────────────────────────
Write-Host "5) Pruning Logs\ (keeping last 10 dated logs)..." -ForegroundColor Yellow
$logsDir = Join-Path $root "Logs"
if (Test-Path $logsDir) {
    $dated = Get-ChildItem $logsDir -Filter "AD_Mail_Sync_*.log" |
             Sort-Object LastWriteTime -Descending
    $discard = $dated | Select-Object -Skip 10
    foreach ($old in $discard) {
        Move-ToArchive $old.FullName "old_logs"
    }
    # Keep all named logs (AllEKKEmployees_Log.txt etc.) untouched
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  Cleanup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Archive location : $archive" -ForegroundColor White
Write-Host "  Nothing was permanently deleted." -ForegroundColor White
Write-Host ""
Write-Host "  Files kept in root:" -ForegroundColor Yellow
Get-ChildItem $root -File | ForEach-Object {
    Write-Host ("    {0,-45} {1,8} bytes" -f $_.Name, $_.Length) -ForegroundColor White
}
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""
