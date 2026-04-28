<#
.SYNOPSIS
    Syncs the LogisticsAllEmployees AD group — Logistics division.
.PARAMETER Test          Dry-run, no AD changes.
.PARAMETER Auto          No prompts (scheduled runs).
.PARAMETER UseCredential Prompt for alternate AD credentials.
.PARAMETER Diagnose      Report Logistics dept users NOT in AllEKKEmployees.
#>
param([switch]$Test, [switch]$Auto, [switch]$UseCredential, [switch]$Diagnose)

# ══════════════════════════════════════════════════════════════════════════════
$SourceGroup = "AllEKKEmployees"
$TargetGroup = "LogisticsAllEmployees"
$LogDir      = "C:\AD-MailSync\Logs"
$LogFile     = Join-Path $LogDir ("LogisticsAllEmployees_Sync_{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

$Departments = @(
    "Documentation - LOG"
    "Operations - LOG"
    "Customs Clearance - LOG"
    "Logistics"
    "MIS, Administration and Support - LOG"
)
# ══════════════════════════════════════════════════════════════════════════════

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Write-Log {
    param([string]$Message, [ValidateSet("INFO","SUCCESS","WARN","ERROR","HEADER")][string]$Level = "INFO")
    $line = "[{0}] [{1,-7}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    $line | Out-File -FilePath $LogFile -Append -Encoding UTF8
    Write-Host $line -ForegroundColor $(switch ($Level) {"SUCCESS"{"Green"}"WARN"{"Yellow"}"ERROR"{"Red"}"HEADER"{"Cyan"}default{"White"}})
}

Write-Log "================================================================" "HEADER"
Write-Log "  LogisticsAllEmployees Group Sync  —  $(Get-Date -Format 'dd-MMM-yyyy HH:mm')" "HEADER"
Write-Log "  Source : $SourceGroup  →  Target : $TargetGroup" "HEADER"
Write-Log "  Mode   : $(if($Test){'TEST (dry-run)'}elseif($UseCredential){'LIVE (alternate credentials)'}else{'LIVE'})" "HEADER"
Write-Log "================================================================" "HEADER"
if ($Test) { Write-Host "`n  *** TEST MODE ***`n" -ForegroundColor Yellow }

try { Import-Module ActiveDirectory -ErrorAction Stop; Write-Log "ActiveDirectory module loaded." }
catch { Write-Log "ActiveDirectory module not found. Install RSAT." "ERROR"; exit 1 }

# Build credential splatting hashtable once
$adParams = @{}
if ($UseCredential) {
    Write-Host "`n  Enter credentials with Write Members on '$TargetGroup'`n" -ForegroundColor Cyan
    $adCred = Get-Credential
    if (-not $adCred) { Write-Log "No credentials supplied." "ERROR"; exit 1 }
    $adParams['Credential'] = $adCred
    Write-Log ("Credentials: {0}" -f $adCred.UserName)
}

# Verify groups exist
foreach ($grp in @($SourceGroup, $TargetGroup)) {
    try { Get-ADGroup -Identity $grp @adParams -ErrorAction Stop | Out-Null; Write-Log "Group verified: $grp" }
    catch { Write-Log "Group '$grp' not found: $_" "ERROR"; exit 1 }
}

# Step 1 — Read source and filter
Write-Log "--- Step 1: Reading $SourceGroup members ---"
try {
    $allEKK = Get-ADGroupMember -Identity $SourceGroup -Recursive @adParams |
        Where-Object { $_.objectClass -eq 'user' } |
        ForEach-Object { Get-ADUser -Identity $_.DistinguishedName @adParams -Properties DisplayName,Department,SamAccountName }
    Write-Log ("Total users in {0}: {1}" -f $SourceGroup, $allEKK.Count)
} catch { Write-Log "Failed to read '$SourceGroup': $_" "ERROR"; exit 1 }

$filtered = $allEKK | Where-Object { $dept=$_.Department; $Departments | Where-Object { $_ -ieq $dept } }
Write-Log ("Matched users: {0}" -f $filtered.Count) "INFO"
if ($filtered.Count -eq 0) { Write-Log "No users matched. Check department names." "WARN"; exit 0 }
Write-Log "Breakdown:"; $filtered | Group-Object Department | Sort-Object Count -Descending | ForEach-Object { Write-Log ("  {0,4}  {1}" -f $_.Count,$_.Name) }

# Step 2 — Read target group
Write-Log "--- Step 2: Reading current $TargetGroup members ---"
try {
    $current = Get-ADGroupMember -Identity $TargetGroup -Recursive @adParams | Where-Object { $_.objectClass -eq 'user' } |
        ForEach-Object { Get-ADUser -Identity $_.DistinguishedName @adParams -Properties DisplayName,Department,SamAccountName }
    $currentDNs = $current | Select-Object -ExpandProperty DistinguishedName
    Write-Log ("Current members in {0}: {1}" -f $TargetGroup, $current.Count)
} catch { Write-Log "Failed to read '$TargetGroup': $_" "ERROR"; exit 1 }

# Step 3 — Delta
Write-Log "--- Step 3: Calculating changes ---"
$toAdd    = $filtered | Where-Object { $currentDNs -notcontains $_.DistinguishedName }
$toRemove = $current  | Where-Object { $dept=$_.Department; -not ($Departments | Where-Object { $_ -ieq $dept }) }
Write-Log ("  Already correct: {0}" -f ($filtered | Where-Object { $currentDNs -contains $_.DistinguishedName }).Count)
Write-Log ("  To ADD         : {0}" -f $toAdd.Count) "INFO"
Write-Log ("  To REMOVE      : {0}" -f $toRemove.Count) "INFO"

if ($toAdd.Count -eq 0 -and $toRemove.Count -eq 0) {
    Write-Log "$TargetGroup is already in sync." "SUCCESS"
} else {
    if (-not $Auto -and -not $Test) {
        Write-Host ("`n  Pending: ADD {0},  REMOVE {1}" -f $toAdd.Count,$toRemove.Count) -ForegroundColor Cyan
        if ((Read-Host "  Proceed? (yes/no)") -notmatch '^y') { Write-Log "Cancelled." "WARN"; exit 0 }
    }

    $addedOK=0; $addedErr=0
    if ($toAdd.Count -gt 0) {
        Write-Log "--- Adding $($toAdd.Count) users ---"
        if ($Test) {
            $toAdd | Sort-Object DisplayName | ForEach-Object { Write-Log ("  [DRY-RUN ADD] {0} ({1}) [{2}]" -f $_.DisplayName,$_.SamAccountName,$_.Department) }
            $addedOK = $toAdd.Count
        } else {
            try {
                Add-ADGroupMember -Identity $TargetGroup -Members ($toAdd|Select-Object -ExpandProperty DistinguishedName) @adParams -ErrorAction Stop
                $addedOK=$toAdd.Count; Write-Log ("  [BATCH ADDED] {0} users." -f $addedOK) "SUCCESS"
            } catch {
                Write-Log "Batch failed, switching to per-user: $_" "WARN"
                foreach ($u in $toAdd|Sort-Object DisplayName) {
                    try { Add-ADGroupMember -Identity $TargetGroup -Members $u.DistinguishedName @adParams -ErrorAction Stop; Write-Log "  [ADDED] $($u.DisplayName)" "SUCCESS"; $addedOK++ }
                    catch { Write-Log "  [ERROR] $($u.DisplayName) — $_" "ERROR"; $addedErr++ }
                }
            }
        }
    }

    $removedOK=0; $removedErr=0
    if ($toRemove.Count -gt 0) {
        Write-Log "--- Removing $($toRemove.Count) users ---"
        foreach ($u in $toRemove|Sort-Object DisplayName) {
            $label="{0} ({1}) [{2}]" -f $u.DisplayName,$u.SamAccountName,$u.Department
            if ($Test) { Write-Log "  [DRY-RUN REMOVE] $label" "WARN"; $removedOK++ }
            else {
                try { Remove-ADGroupMember -Identity $TargetGroup -Members $u.DistinguishedName @adParams -Confirm:$false -ErrorAction Stop; Write-Log "  [REMOVED] $label" "WARN"; $removedOK++ }
                catch { Write-Log "  [REMOVE ERROR] $label — $_" "ERROR"; $removedErr++ }
            }
        }
    }

    Write-Log "================================================================" "HEADER"
    Write-Log "  SYNC SUMMARY$(if($Test){' (TEST)'})" "HEADER"
    Write-Log "----------------------------------------------------------------" "HEADER"
    Write-Log ("  Matched dept users : {0}" -f $filtered.Count)
    if ($Test) { Write-Log ("  Would ADD          : {0}" -f $addedOK) "SUCCESS"; Write-Log ("  Would REMOVE       : {0}" -f $removedOK) "WARN" }
    else {
        Write-Log ("  ADDED              : {0}" -f $addedOK) "SUCCESS"; Write-Log ("  REMOVED            : {0}" -f $removedOK) "WARN"
        if ($addedErr   -gt 0) { Write-Log ("  ADD errors         : {0}" -f $addedErr)   "ERROR" }
        if ($removedErr -gt 0) { Write-Log ("  REMOVE errors      : {0}" -f $removedErr) "ERROR" }
    }
}

if ($Diagnose) {
    Write-Log "================================================================" "HEADER"
    Write-Log "  DIAGNOSTIC: dept users NOT in $SourceGroup" "HEADER"
    $ekk_DNs = $allEKK | Select-Object -ExpandProperty DistinguishedName
    $allInAD = @(); foreach ($d in $Departments) { $allInAD += Get-ADUser -Filter "Department -eq '$d' -and Enabled -eq `$true" -Properties DisplayName,Department,SamAccountName @adParams }
    $allInAD = $allInAD | Sort-Object DistinguishedName -Unique
    $missing = $allInAD | Where-Object { $ekk_DNs -notcontains $_.DistinguishedName }
    Write-Log ("  In AD with matching dept : {0}" -f $allInAD.Count)
    Write-Log ("  NOT in {0}   : {1}" -f $SourceGroup,$missing.Count) $(if($missing.Count -gt 0){"WARN"}else{"SUCCESS"})
    $missing | Sort-Object DisplayName | ForEach-Object { Write-Log ("    {0} ({1}) [{2}]" -f $_.DisplayName,$_.SamAccountName,$_.Department) "WARN" }
}

Write-Log ("  Log: $LogFile"); Write-Log "================================================================" "HEADER"
