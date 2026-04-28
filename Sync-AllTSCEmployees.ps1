<#
.SYNOPSIS
    Syncs the AllTSCEmployees AD group based on Department membership.

.DESCRIPTION
    Reads all members of AllEKKEmployees, filters by the configured TSC
    department list, then:
      - ADDS   users whose Department matches but are not yet in AllTSCEmployees
      - REMOVES users who ARE in AllTSCEmployees but whose Department no
                longer matches (e.g. they transferred out of TSC)

    Users remain members of AllEKKEmployees regardless.

.PARAMETER Test
    Dry-run mode — shows what would change, makes NO AD modifications.

.PARAMETER Auto
    Suppresses all prompts (for scheduled / unattended runs).

.EXAMPLE
    # Preview changes only
    PowerShell -ExecutionPolicy Bypass -File .\Sync-AllTSCEmployees.ps1 -Test

    # Live run (interactive)
    PowerShell -ExecutionPolicy Bypass -File .\Sync-AllTSCEmployees.ps1

    # Scheduled / silent
    PowerShell -NoProfile -ExecutionPolicy Bypass -File .\Sync-AllTSCEmployees.ps1 -Auto
#>

param(
    [switch]$Test,
    [switch]$Auto
)

# ══════════════════════════════════════════════════════════════════════════════
#  CONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════

$SourceGroup = "AllEKKEmployees"
$TargetGroup = "AllTSCEmployees"
$LogDir      = "C:\AD-MailSync\Logs"
$LogFile     = Join-Path $LogDir ("AllTSCEmployees_Sync_{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

# Departments whose members should be in AllTSCEmployees.
# Edit this list if departments are renamed or new ones are added.
$TSC_Departments = @(
    "Business Development Centre - TLAS"
    "New Car Delivery Centre"
    "Special Assignments - TLAS"
    "Toyota and Lexus After-Sales"
    "Toyota and Lexus After-Sales Support - TLAS"
    "Toyota Body Service Centre - Arad"
    "Toyota Body Service Centre - Plaza"
    "Toyota Commercial Body Service Centre - Plaza"
    "Toyota Commercial Service Centre - Plaza"
    "Toyota Service Centre - Alba"
    "Toyota Service Centre - Arad"
    "Toyota Service Centre - Janabiyah"
    "Toyota Service Centre - Manama"
    "Toyota Service Centre - Plaza"
    "Toyota Service Centre - Riffa"
    "Toyota Service Centre - Sitra"
)

# ══════════════════════════════════════════════════════════════════════════════
#  LOGGING
# ══════════════════════════════════════════════════════════════════════════════

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","SUCCESS","WARN","ERROR","HEADER")]
        [string]$Level = "INFO"
    )
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[{0}] [{1,-7}] {2}" -f $ts, $Level, $Message
    $line | Out-File -FilePath $LogFile -Append -Encoding UTF8

    $colour = switch ($Level) {
        "SUCCESS" { "Green"   }
        "WARN"    { "Yellow"  }
        "ERROR"   { "Red"     }
        "HEADER"  { "Cyan"    }
        default   { "White"   }
    }
    Write-Host $line -ForegroundColor $colour
}

# ══════════════════════════════════════════════════════════════════════════════
#  BANNER
# ══════════════════════════════════════════════════════════════════════════════

Write-Log "================================================================" "HEADER"
Write-Log "  AllTSCEmployees Group Sync  —  $(Get-Date -Format 'dd-MMM-yyyy HH:mm')" "HEADER"
Write-Log "  Source : $SourceGroup" "HEADER"
Write-Log "  Target : $TargetGroup" "HEADER"
Write-Log "  Mode   : $(if ($Test) { 'TEST (dry-run — no AD changes)' } else { 'LIVE' })" "HEADER"
Write-Log "================================================================" "HEADER"

if ($Test) {
    Write-Host ""
    Write-Host "  *** TEST MODE: all changes are simulated only ***" -ForegroundColor Yellow
    Write-Host ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  PREREQUISITES
# ══════════════════════════════════════════════════════════════════════════════

try {
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Log "ActiveDirectory module loaded."
} catch {
    Write-Log "ActiveDirectory module not found. Install RSAT and retry." "ERROR"
    exit 1
}

# Verify both groups exist
foreach ($grp in @($SourceGroup, $TargetGroup)) {
    try {
        Get-ADGroup -Identity $grp -ErrorAction Stop | Out-Null
        Write-Log "Group verified: $grp"
    } catch {
        Write-Log "Group '$grp' not found in AD. $_" "ERROR"
        exit 1
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 1 — Read AllEKKEmployees and filter by TSC departments
# ══════════════════════════════════════════════════════════════════════════════

Write-Log "--- Step 1: Reading $SourceGroup members ---" "INFO"

try {
    $allEKK = Get-ADGroupMember -Identity $SourceGroup -Recursive |
        Where-Object { $_.objectClass -eq 'user' } |
        ForEach-Object {
            Get-ADUser -Identity $_.DistinguishedName `
                -Properties DisplayName, Department, EmailAddress, SamAccountName
        }
    Write-Log ("Total members in {0}: {1}" -f $SourceGroup, $allEKK.Count)
} catch {
    Write-Log "Failed to read '$SourceGroup': $_" "ERROR"
    exit 1
}

# Filter to TSC departments (case-insensitive exact match)
$tscFiltered = $allEKK | Where-Object {
    $dept = $_.Department
    $TSC_Departments | Where-Object { $_ -ieq $dept }
}

Write-Log ("Users matching TSC departments: {0}" -f $tscFiltered.Count) "INFO"

if ($tscFiltered.Count -eq 0) {
    Write-Log "No users matched. Verify Department values in AD match the list in this script." "WARN"
    Write-Log "Configured departments:" "WARN"
    $TSC_Departments | ForEach-Object { Write-Log "  - $_" "WARN" }
    exit 0
}

# Department breakdown
Write-Log "Department breakdown:"
$tscFiltered | Group-Object Department | Sort-Object Count -Descending | ForEach-Object {
    Write-Log ("  {0,4}  {1}" -f $_.Count, $_.Name)
}

$tscDNs = $tscFiltered | Select-Object -ExpandProperty DistinguishedName

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 2 — Read current AllTSCEmployees members
# ══════════════════════════════════════════════════════════════════════════════

Write-Log "--- Step 2: Reading current $TargetGroup members ---" "INFO"

try {
    $currentTSC = Get-ADGroupMember -Identity $TargetGroup -Recursive |
        Where-Object { $_.objectClass -eq 'user' } |
        ForEach-Object {
            Get-ADUser -Identity $_.DistinguishedName `
                -Properties DisplayName, Department, EmailAddress, SamAccountName
        }
    $currentDNs = $currentTSC | Select-Object -ExpandProperty DistinguishedName
    Write-Log ("Current members in {0}: {1}" -f $TargetGroup, $currentTSC.Count)
} catch {
    Write-Log "Failed to read '$TargetGroup': $_" "ERROR"
    exit 1
}

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 3 — Calculate delta
# ══════════════════════════════════════════════════════════════════════════════

Write-Log "--- Step 3: Calculating changes ---" "INFO"

# To ADD: in filtered TSC list but not yet in AllTSCEmployees
$toAdd = $tscFiltered | Where-Object { $currentDNs -notcontains $_.DistinguishedName }

# To REMOVE: currently in AllTSCEmployees but department no longer matches TSC list
$toRemove = $currentTSC | Where-Object {
    $dept = $_.Department
    -not ($TSC_Departments | Where-Object { $_ -ieq $dept })
}

$alreadyCorrect = $tscFiltered | Where-Object { $currentDNs -contains $_.DistinguishedName }

Write-Log ("  Already correct (no change): {0}" -f $alreadyCorrect.Count)
Write-Log ("  To ADD                     : {0}" -f $toAdd.Count)    "INFO"
Write-Log ("  To REMOVE                  : {0}" -f $toRemove.Count) "INFO"

if ($toAdd.Count -eq 0 -and $toRemove.Count -eq 0) {
    Write-Log "$TargetGroup is already fully in sync. Nothing to do." "SUCCESS"
    Write-Log "===== Sync Complete — no changes needed =====" "SUCCESS"
    exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 4 — Confirm (interactive mode only)
# ══════════════════════════════════════════════════════════════════════════════

if (-not $Auto -and -not $Test) {
    Write-Host ""
    Write-Host "  Pending changes:" -ForegroundColor Cyan
    Write-Host ("    ADD    {0} users" -f $toAdd.Count)    -ForegroundColor Green
    Write-Host ("    REMOVE {0} users" -f $toRemove.Count) -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "  Proceed? (yes/no)"
    if ($confirm -notmatch '^y') {
        Write-Log "User cancelled. No changes made." "WARN"
        exit 0
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 5 — Apply changes
# ══════════════════════════════════════════════════════════════════════════════

$addedOK = 0; $addedErr = 0
$removedOK = 0; $removedErr = 0

# --- ADD ---
if ($toAdd.Count -gt 0) {
    Write-Log "--- Adding users ---" "INFO"
    foreach ($user in $toAdd | Sort-Object DisplayName) {
        $label = "{0} ({1}) [{2}]" -f $user.DisplayName, $user.SamAccountName, $user.Department
        if ($Test) {
            Write-Log "  [DRY-RUN ADD] $label" "INFO"
            $addedOK++
        } else {
            try {
                Add-ADGroupMember -Identity $TargetGroup -Members $user.DistinguishedName -ErrorAction Stop
                Write-Log "  [ADDED] $label" "SUCCESS"
                $addedOK++
            } catch {
                Write-Log "  [ADD ERROR] $label — $_" "ERROR"
                $addedErr++
            }
        }
    }
}

# --- REMOVE ---
if ($toRemove.Count -gt 0) {
    Write-Log "--- Removing users (department no longer TSC) ---" "INFO"
    foreach ($user in $toRemove | Sort-Object DisplayName) {
        $label = "{0} ({1}) [{2}]" -f $user.DisplayName, $user.SamAccountName, $user.Department
        if ($Test) {
            Write-Log "  [DRY-RUN REMOVE] $label" "WARN"
            $removedOK++
        } else {
            try {
                Remove-ADGroupMember -Identity $TargetGroup -Members $user.DistinguishedName `
                    -Confirm:$false -ErrorAction Stop
                Write-Log "  [REMOVED] $label" "WARN"
                $removedOK++
            } catch {
                Write-Log "  [REMOVE ERROR] $label — $_" "ERROR"
                $removedErr++
            }
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  SUMMARY
# ══════════════════════════════════════════════════════════════════════════════

Write-Log "================================================================" "HEADER"
Write-Log "  SYNC SUMMARY$(if ($Test) { '  (TEST — no real changes)' })" "HEADER"
Write-Log "----------------------------------------------------------------" "HEADER"
Write-Log ("  TSC-matched users in {0}   : {1}" -f $SourceGroup, $tscFiltered.Count)
Write-Log ("  Members already correct        : {0}" -f $alreadyCorrect.Count)
if ($Test) {
    Write-Log ("  Would be ADDED                 : {0}" -f $addedOK)   "SUCCESS"
    Write-Log ("  Would be REMOVED               : {0}" -f $removedOK) "WARN"
} else {
    Write-Log ("  ADDED successfully             : {0}" -f $addedOK)   "SUCCESS"
    Write-Log ("  REMOVED successfully           : {0}" -f $removedOK) "WARN"
    if ($addedErr -gt 0)   { Write-Log ("  ADD errors                     : {0}" -f $addedErr)   "ERROR" }
    if ($removedErr -gt 0) { Write-Log ("  REMOVE errors                  : {0}" -f $removedErr) "ERROR" }
}
Write-Log "----------------------------------------------------------------" "HEADER"
Write-Log ("  Log file: $LogFile") "INFO"
Write-Log "================================================================" "HEADER"
