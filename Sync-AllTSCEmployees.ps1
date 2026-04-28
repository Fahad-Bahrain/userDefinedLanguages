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

.PARAMETER UseCredential
    Prompts for alternate AD credentials (e.g. a Domain Admin account).
    Use this when the running account lacks Write Members on AllTSCEmployees.

.PARAMETER Diagnose
    After the main sync, scans ALL AD users with matching departments to
    identify anyone NOT in AllEKKEmployees (explains count discrepancies).

.EXAMPLE
    # Preview changes only
    PowerShell -ExecutionPolicy Bypass -File .\Sync-AllTSCEmployees.ps1 -Test

    # Live run with DA credentials (fixes "Insufficient access rights")
    PowerShell -ExecutionPolicy Bypass -File .\Sync-AllTSCEmployees.ps1 -UseCredential

    # Live run + show missing users report
    PowerShell -ExecutionPolicy Bypass -File .\Sync-AllTSCEmployees.ps1 -UseCredential -Diagnose

    # Scheduled / silent (service account must already have Write Members)
    PowerShell -NoProfile -ExecutionPolicy Bypass -File .\Sync-AllTSCEmployees.ps1 -Auto
#>

param(
    [switch]$Test,
    [switch]$Auto,
    [switch]$UseCredential,
    [switch]$Diagnose
)

# ══════════════════════════════════════════════════════════════════════════════
#  CONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════

$SourceGroup = "AllEKKEmployees"
$TargetGroup = "AllTSCEmployees"
$LogDir      = "C:\AD-MailSync\Logs"
$LogFile     = Join-Path $LogDir ("AllTSCEmployees_Sync_{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

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
        "SUCCESS" { "Green"  }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red"    }
        "HEADER"  { "Cyan"   }
        default   { "White"  }
    }
    Write-Host $line -ForegroundColor $colour
}

# ══════════════════════════════════════════════════════════════════════════════
#  BANNER
# ══════════════════════════════════════════════════════════════════════════════

Write-Log "================================================================" "HEADER"
Write-Log "  AllTSCEmployees Group Sync  —  $(Get-Date -Format 'dd-MMM-yyyy HH:mm')" "HEADER"
Write-Log "  Source : $SourceGroup  →  Target : $TargetGroup" "HEADER"
Write-Log "  Mode   : $(if ($Test) { 'TEST (dry-run)' } elseif ($UseCredential) { 'LIVE (with alternate credentials)' } else { 'LIVE' })" "HEADER"
Write-Log "================================================================" "HEADER"

if ($Test) {
    Write-Host "`n  *** TEST MODE: all changes are simulated only ***`n" -ForegroundColor Yellow
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

# Collect credentials if requested
$adCred = $null
if ($UseCredential) {
    Write-Host ""
    Write-Host "  Enter credentials with Write Members permission on '$TargetGroup'" -ForegroundColor Cyan
    Write-Host "  (e.g. DOMAIN\Administrator or your DA account)" -ForegroundColor Cyan
    Write-Host ""
    $adCred = Get-Credential
    if (-not $adCred) {
        Write-Log "No credentials supplied. Exiting." "ERROR"
        exit 1
    }
    Write-Log ("Credentials supplied for: {0}" -f $adCred.UserName)
}

# Helper: build common AD splatting params
function Get-ADParams {
    $p = @{}
    if ($adCred) { $p['Credential'] = $adCred }
    return $p
}

# Verify both groups exist
foreach ($grp in @($SourceGroup, $TargetGroup)) {
    try {
        Get-ADGroup -Identity $grp @(Get-ADParams) -ErrorAction Stop | Out-Null
        Write-Log "Group verified: $grp"
    } catch {
        Write-Log "Group '$grp' not found in AD. $_" "ERROR"
        exit 1
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 1 — Read AllEKKEmployees and filter by TSC departments
# ══════════════════════════════════════════════════════════════════════════════

Write-Log "--- Step 1: Reading $SourceGroup members ---"

try {
    $adParams = Get-ADParams
    $allEKK = Get-ADGroupMember -Identity $SourceGroup -Recursive @adParams |
        Where-Object { $_.objectClass -eq 'user' } |
        ForEach-Object {
            Get-ADUser -Identity $_.DistinguishedName @adParams `
                -Properties DisplayName, Department, EmailAddress, SamAccountName
        }
    Write-Log ("Total users in {0}: {1}" -f $SourceGroup, $allEKK.Count)
} catch {
    Write-Log "Failed to read '$SourceGroup': $_" "ERROR"
    exit 1
}

$tscFiltered = $allEKK | Where-Object {
    $dept = $_.Department
    $TSC_Departments | Where-Object { $_ -ieq $dept }
}

Write-Log ("Users matching TSC departments: {0}" -f $tscFiltered.Count) "INFO"

if ($tscFiltered.Count -eq 0) {
    Write-Log "No users matched. Verify Department values in AD match the list in this script." "WARN"
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

Write-Log "--- Step 2: Reading current $TargetGroup members ---"

try {
    $adParams = Get-ADParams
    $currentTSC = Get-ADGroupMember -Identity $TargetGroup -Recursive @adParams |
        Where-Object { $_.objectClass -eq 'user' } |
        ForEach-Object {
            Get-ADUser -Identity $_.DistinguishedName @adParams `
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

Write-Log "--- Step 3: Calculating changes ---"

$toAdd    = $tscFiltered | Where-Object { $currentDNs -notcontains $_.DistinguishedName }
$toRemove = $currentTSC  | Where-Object {
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
} else {

    # ── Confirm (interactive) ─────────────────────────────────────────────────
    if (-not $Auto -and -not $Test) {
        Write-Host ""
        Write-Host ("  Pending: ADD {0} users,  REMOVE {1} users" -f $toAdd.Count, $toRemove.Count) -ForegroundColor Cyan
        $confirm = Read-Host "  Proceed? (yes/no)"
        if ($confirm -notmatch '^y') {
            Write-Log "User cancelled. No changes made." "WARN"
            exit 0
        }
    }

    # ── ADD (batch for efficiency, fallback to per-user on error) ─────────────
    $addedOK = 0; $addedErr = 0

    if ($toAdd.Count -gt 0) {
        Write-Log "--- Adding $($toAdd.Count) users (batch) ---"
        if ($Test) {
            $toAdd | Sort-Object DisplayName | ForEach-Object {
                Write-Log ("  [DRY-RUN ADD] {0} ({1}) [{2}]" -f $_.DisplayName, $_.SamAccountName, $_.Department)
            }
            $addedOK = $toAdd.Count
        } else {
            # Try batch add first (most efficient)
            try {
                $adParams = Get-ADParams
                Add-ADGroupMember -Identity $TargetGroup `
                    -Members ($toAdd | Select-Object -ExpandProperty DistinguishedName) `
                    @adParams -ErrorAction Stop
                $addedOK = $toAdd.Count
                Write-Log ("  [BATCH ADDED] {0} users added successfully." -f $addedOK) "SUCCESS"
            } catch {
                Write-Log "Batch add failed, falling back to per-user mode: $_" "WARN"
                # Per-user fallback
                foreach ($user in $toAdd | Sort-Object DisplayName) {
                    $label = "{0} ({1}) [{2}]" -f $user.DisplayName, $user.SamAccountName, $user.Department
                    try {
                        $adParams = Get-ADParams
                        Add-ADGroupMember -Identity $TargetGroup `
                            -Members $user.DistinguishedName @adParams -ErrorAction Stop
                        Write-Log "  [ADDED] $label" "SUCCESS"
                        $addedOK++
                    } catch {
                        Write-Log "  [ADD ERROR] $label — $_" "ERROR"
                        $addedErr++
                    }
                }
            }
        }
    }

    # ── REMOVE ────────────────────────────────────────────────────────────────
    $removedOK = 0; $removedErr = 0

    if ($toRemove.Count -gt 0) {
        Write-Log "--- Removing $($toRemove.Count) users (dept no longer TSC) ---"
        foreach ($user in $toRemove | Sort-Object DisplayName) {
            $label = "{0} ({1}) [{2}]" -f $user.DisplayName, $user.SamAccountName, $user.Department
            if ($Test) {
                Write-Log "  [DRY-RUN REMOVE] $label" "WARN"
                $removedOK++
            } else {
                try {
                    $adParams = Get-ADParams
                    Remove-ADGroupMember -Identity $TargetGroup `
                        -Members $user.DistinguishedName @adParams -Confirm:$false -ErrorAction Stop
                    Write-Log "  [REMOVED] $label" "WARN"
                    $removedOK++
                } catch {
                    Write-Log "  [REMOVE ERROR] $label — $_" "ERROR"
                    $removedErr++
                }
            }
        }
    }

    # ── Summary ───────────────────────────────────────────────────────────────
    Write-Log "================================================================" "HEADER"
    Write-Log "  SYNC SUMMARY$(if ($Test) { '  (TEST — no real changes)' })" "HEADER"
    Write-Log "----------------------------------------------------------------" "HEADER"
    Write-Log ("  TSC-matched in {0}          : {1}" -f $SourceGroup, $tscFiltered.Count)
    Write-Log ("  Already correct                : {0}" -f $alreadyCorrect.Count)
    if ($Test) {
        Write-Log ("  Would be ADDED                 : {0}" -f $addedOK)   "SUCCESS"
        Write-Log ("  Would be REMOVED               : {0}" -f $removedOK) "WARN"
    } else {
        Write-Log ("  ADDED successfully             : {0}" -f $addedOK)   "SUCCESS"
        Write-Log ("  REMOVED successfully           : {0}" -f $removedOK) "WARN"
        if ($addedErr   -gt 0) { Write-Log ("  ADD errors                     : {0}  ← check permissions" -f $addedErr)   "ERROR" }
        if ($removedErr -gt 0) { Write-Log ("  REMOVE errors                  : {0}" -f $removedErr) "ERROR" }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  OPTIONAL: DIAGNOSE missing users (why count < expected)
# ══════════════════════════════════════════════════════════════════════════════

if ($Diagnose) {
    Write-Log "================================================================" "HEADER"
    Write-Log "  DIAGNOSTIC: Finding TSC users NOT in $SourceGroup" "HEADER"
    Write-Log "----------------------------------------------------------------" "HEADER"
    Write-Log "Searching all AD users with matching department attributes..."

    try {
        $adParams = Get-ADParams
        $ekk_DNs  = $allEKK | Select-Object -ExpandProperty DistinguishedName

        $allTSCInAD = @()
        foreach ($dept in $TSC_Departments) {
            $found = Get-ADUser -Filter "Department -eq '$dept' -and Enabled -eq `$true" `
                -Properties DisplayName, Department, SamAccountName @adParams
            $allTSCInAD += $found
        }
        $allTSCInAD = $allTSCInAD | Sort-Object DistinguishedName -Unique

        Write-Log ("  Total enabled AD users with TSC departments : {0}" -f $allTSCInAD.Count)
        Write-Log ("  Members found via $SourceGroup              : {0}" -f $tscFiltered.Count)

        $notInEKK = $allTSCInAD | Where-Object { $ekk_DNs -notcontains $_.DistinguishedName }

        if ($notInEKK.Count -eq 0) {
            Write-Log "  All TSC dept users ARE in $SourceGroup. Count difference may be disabled accounts." "SUCCESS"
        } else {
            Write-Log ("  Users with TSC dept but NOT in {0}: {1}" -f $SourceGroup, $notInEKK.Count) "WARN"
            Write-Log "  These users need to be added to $SourceGroup first:" "WARN"
            $notInEKK | Sort-Object DisplayName | ForEach-Object {
                Write-Log ("    {0,-40} ({1,-20}) [{2}]" -f $_.DisplayName, $_.SamAccountName, $_.Department) "WARN"
            }
        }
    } catch {
        Write-Log "Diagnostic query failed: $_" "ERROR"
    }
}

Write-Log "----------------------------------------------------------------" "HEADER"
Write-Log ("  Log : $LogFile")
Write-Log "================================================================" "HEADER"
