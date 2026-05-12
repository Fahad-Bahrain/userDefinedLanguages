<#
.SYNOPSIS
    Syncs the EK Kanoo Tyres Division Group AD group based on Department membership.
.PARAMETER Test          Dry-run, no AD changes.
.PARAMETER Auto          No prompts (scheduled runs).
.PARAMETER UseCredential Prompt for alternate AD credentials interactively.
.PARAMETER Diagnose      Report EKK Tyres dept users NOT in AllEKKEmployees.
.PARAMETER ADUsername    AD username passed from master script (e.g. ekkorg\ict.support).
.PARAMETER ADPassword    DPAPI-encrypted password string passed from master script.
#>

param(
    [switch]$Test,
    [switch]$Auto,
    [switch]$UseCredential,
    [switch]$Diagnose,
    [string]$ADUsername = "",
    [string]$ADPassword = ""
)

$SourceGroup = "AllEKKEmployees"
$TargetGroup = "EK Kanoo Tyres Division Group"
$LogDir      = "C:\AD-MailSync\Logs"
$LogFile     = Join-Path $LogDir ("EKKTyresEmployees_Sync_{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

$EKKTyres_Departments = @(
    "EK Kanoo Tyres"
    "Michelin Truck Service Centre"
    "Tyre Operations"
    "Tyre Plus - Diplomatic Area"
    "Tyre Plus - Diyar Al Muharraq"
    "Tyre Plus - Hamad Town R14"
    "Tyre Plus - Hamad Town R2"
    "Tyre Plus - Hidd"
    "Tyre Plus - Isa Town"
    "Tyre Plus - Muharraq"
    "Tyre Plus - Saar"
    "Tyre Plus - Salmabad"
    "Tyre Plus - Sitra"
    "Tyre Plus - Tubli"
    "Tyre Plus Operations"
)

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Write-Log {
    param([string]$Message, [ValidateSet("INFO","SUCCESS","WARN","ERROR","HEADER")][string]$Level = "INFO")
    $line = "[{0}] [{1,-7}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    $line | Out-File -FilePath $LogFile -Append -Encoding UTF8
    Write-Host $line -ForegroundColor $(switch ($Level) {"SUCCESS"{"Green"}"WARN"{"Yellow"}"ERROR"{"Red"}"HEADER"{"Cyan"}default{"White"}})
}

Write-Log "================================================================" "HEADER"
Write-Log "  EK Kanoo Tyres Division Group Sync  -  $(Get-Date -Format 'dd-MMM-yyyy HH:mm')" "HEADER"
Write-Log "  Source : $SourceGroup  |  Target : $TargetGroup" "HEADER"
Write-Log "  Mode   : $(if ($Test) { 'TEST (dry-run)' } elseif ($ADUsername) { 'LIVE (credentials from master)' } elseif ($UseCredential) { 'LIVE (alternate credentials)' } else { 'LIVE' })" "HEADER"
Write-Log "================================================================" "HEADER"
if ($Test) { Write-Host "`n  *** TEST MODE ***`n" -ForegroundColor Yellow }

try { Import-Module ActiveDirectory -ErrorAction Stop; Write-Log "ActiveDirectory module loaded." }
catch { Write-Log "ActiveDirectory module not found. Install RSAT." "ERROR"; exit 1 }

$adParams = @{}
if ($ADUsername -and $ADPassword) {
    try {
        $secPass = ConvertTo-SecureString $ADPassword
        $adCred  = New-Object PSCredential($ADUsername, $secPass)
        $adParams['Credential'] = $adCred
        Write-Log ("Running as: {0} (passed from master script)" -f $adCred.UserName)
    } catch { Write-Log "Failed to reconstruct credentials: $_" "ERROR"; exit 1 }
} elseif ($UseCredential) {
    Write-Host "`n  Enter credentials with Write Members on '$TargetGroup' (e.g. ekkorg\ict.support)`n" -ForegroundColor Cyan
    $adCred = Get-Credential
    if (-not $adCred) { Write-Log "No credentials supplied." "ERROR"; exit 1 }
    $adParams['Credential'] = $adCred
    Write-Log ("Running as: {0}" -f $adCred.UserName)
}

foreach ($grp in @($SourceGroup, $TargetGroup)) {
    try { Get-ADGroup -Identity $grp @adParams -ErrorAction Stop | Out-Null; Write-Log "Group verified: $grp" }
    catch { Write-Log "Group '$grp' not found: $_" "ERROR"; exit 1 }
}

Write-Log "--- Step 1: Reading $SourceGroup members ---" "INFO"
try {
    $allEKK = Get-ADGroupMember -Identity $SourceGroup -Recursive @adParams |
        Where-Object { $_.objectClass -eq 'user' } |
        ForEach-Object { Get-ADUser -Identity $_.DistinguishedName @adParams -Properties DisplayName,Department,EmailAddress,SamAccountName }
    Write-Log ("Total members in {0}: {1}" -f $SourceGroup, $allEKK.Count)
} catch { Write-Log "Failed to read '$SourceGroup': $_" "ERROR"; exit 1 }

$tyresFiltered = $allEKK | Where-Object { $dept=$_.Department; $EKKTyres_Departments | Where-Object { $_ -ieq $dept } }
Write-Log ("Users matching EKK Tyres departments: {0}" -f $tyresFiltered.Count) "INFO"
if ($tyresFiltered.Count -eq 0) { Write-Log "No users matched. Verify Department values in AD." "WARN"; exit 0 }
Write-Log "Department breakdown:"
$tyresFiltered | Group-Object Department | Sort-Object Count -Descending | ForEach-Object { Write-Log ("  {0,4}  {1}" -f $_.Count,$_.Name) }

Write-Log "--- Step 2: Reading current $TargetGroup members ---" "INFO"
try {
    $currentTyres = Get-ADGroupMember -Identity $TargetGroup -Recursive @adParams |
        Where-Object { $_.objectClass -eq 'user' } |
        ForEach-Object { Get-ADUser -Identity $_.DistinguishedName @adParams -Properties DisplayName,Department,EmailAddress,SamAccountName }
    $currentDNs = $currentTyres | Select-Object -ExpandProperty DistinguishedName
    Write-Log ("Current members in {0}: {1}" -f $TargetGroup, $currentTyres.Count)
} catch { Write-Log "Failed to read '$TargetGroup': $_" "ERROR"; exit 1 }

Write-Log "--- Step 3: Calculating changes ---" "INFO"
$toAdd          = $tyresFiltered | Where-Object { $currentDNs -notcontains $_.DistinguishedName }
$toRemove       = $currentTyres  | Where-Object { $dept=$_.Department; -not ($EKKTyres_Departments | Where-Object { $_ -ieq $dept }) }
$alreadyCorrect = $tyresFiltered | Where-Object { $currentDNs -contains $_.DistinguishedName }
Write-Log ("  Already correct : {0}" -f $alreadyCorrect.Count)
Write-Log ("  To ADD          : {0}" -f $toAdd.Count) "INFO"
Write-Log ("  To REMOVE       : {0}" -f $toRemove.Count) "INFO"

if ($toAdd.Count -eq 0 -and $toRemove.Count -eq 0) { Write-Log "$TargetGroup is already fully in sync." "SUCCESS"; exit 0 }
if (-not $Auto -and -not $Test) { Write-Host ("`n  Pending: ADD {0},  REMOVE {1}" -f $toAdd.Count,$toRemove.Count) -ForegroundColor Cyan }

$addedOK=0; $addedErr=0; $removedOK=0; $removedErr=0

if ($toAdd.Count -gt 0) {
    Write-Log "--- Adding $($toAdd.Count) users ---" "INFO"
    if ($Test) { $toAdd | Sort-Object DisplayName | ForEach-Object { Write-Log ("  [DRY-RUN ADD] {0} ({1}) [{2}]" -f $_.DisplayName,$_.SamAccountName,$_.Department) }; $addedOK=$toAdd.Count }
    else {
        try {
            Add-ADGroupMember -Identity $TargetGroup -Members ($toAdd|Select-Object -ExpandProperty DistinguishedName) @adParams -ErrorAction Stop
            $addedOK=$toAdd.Count; Write-Log ("  [BATCH ADDED] {0} users." -f $addedOK) "SUCCESS"
        } catch {
            Write-Log "Batch failed, switching to per-user: $_" "WARN"
            foreach ($user in $toAdd|Sort-Object DisplayName) {
                $label="{0} ({1}) [{2}]" -f $user.DisplayName,$user.SamAccountName,$user.Department
                try { Add-ADGroupMember -Identity $TargetGroup -Members $user.DistinguishedName @adParams -ErrorAction Stop; Write-Log "  [ADDED] $label" "SUCCESS"; $addedOK++ }
                catch { Write-Log "  [ADD ERROR] $label - $_" "ERROR"; $addedErr++ }
            }
        }
    }
}

if ($toRemove.Count -gt 0) {
    Write-Log "--- Removing users (department no longer EKK Tyres) ---" "INFO"
    foreach ($user in $toRemove|Sort-Object DisplayName) {
        $label="{0} ({1}) [{2}]" -f $user.DisplayName,$user.SamAccountName,$user.Department
        if ($Test) { Write-Log "  [DRY-RUN REMOVE] $label" "WARN"; $removedOK++ }
        else {
            try { Remove-ADGroupMember -Identity $TargetGroup -Members $user.DistinguishedName @adParams -Confirm:$false -ErrorAction Stop; Write-Log "  [REMOVED] $label" "WARN"; $removedOK++ }
            catch { Write-Log "  [REMOVE ERROR] $label - $_" "ERROR"; $removedErr++ }
        }
    }
}

if ($Diagnose) {
    Write-Log "================================================================" "HEADER"
    Write-Log "  DIAGNOSTIC: EKK Tyres dept users NOT in $SourceGroup" "HEADER"
    $ekk_DNs = $allEKK | Select-Object -ExpandProperty DistinguishedName
    $allInAD = @(); foreach ($d in $EKKTyres_Departments) { $allInAD += Get-ADUser -Filter "Department -eq '$d' -and Enabled -eq `$true" @adParams -Properties DisplayName,Department,SamAccountName }
    $allInAD = $allInAD | Sort-Object DistinguishedName -Unique
    $missing = $allInAD | Where-Object { $ekk_DNs -notcontains $_.DistinguishedName }
    Write-Log ("  In AD with matching dept : {0}" -f $allInAD.Count)
    Write-Log ("  NOT in {0} : {1}" -f $SourceGroup,$missing.Count) $(if($missing.Count -gt 0){"WARN"}else{"SUCCESS"})
    $missing | Sort-Object DisplayName | ForEach-Object { Write-Log ("    {0} ({1}) [{2}]" -f $_.DisplayName,$_.SamAccountName,$_.Department) "WARN" }
}

Write-Log "================================================================" "HEADER"
Write-Log "  SYNC SUMMARY$(if ($Test) { '  (TEST - no real changes)' })" "HEADER"
Write-Log "----------------------------------------------------------------" "HEADER"
Write-Log ("  EKK Tyres-matched users in {0}   : {1}" -f $SourceGroup,$tyresFiltered.Count)
Write-Log ("  Members already correct           : {0}" -f $alreadyCorrect.Count)
if ($Test) { Write-Log ("  Would be ADDED   : {0}" -f $addedOK) "SUCCESS"; Write-Log ("  Would be REMOVED : {0}" -f $removedOK) "WARN" }
else {
    Write-Log ("  ADDED successfully   : {0}" -f $addedOK) "SUCCESS"
    Write-Log ("  REMOVED successfully : {0}" -f $removedOK) "WARN"
    if ($addedErr -gt 0)   { Write-Log ("  ADD errors    : {0}" -f $addedErr)   "ERROR" }
    if ($removedErr -gt 0) { Write-Log ("  REMOVE errors : {0}" -f $removedErr) "ERROR" }
}
Write-Log ("  Log file: $LogFile") "INFO"
Write-Log "================================================================" "HEADER"
