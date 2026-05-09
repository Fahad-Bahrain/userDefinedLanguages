<# =====================================================================
 ad-sync_silent_PATCHED.ps1  (headless AD Mail Sync)

 Changes in this build:
 - Renamed primary group from "AllMailUsers" to "AllEKKEmployees".
 - CSV retention: keep the 10 most recent CSV files per type.
 - Log retention: delete *.log files older than 15 days.
 - Fixed: try/catch inside hashtable in Pick-BestAccount.
 - HTML email report matching division sync format.
===================================================================== #>

[CmdletBinding()]
param(
  [string]$Server,
  [string]$CredPath      = "C:\AD-MailSync\cred.xml",
  [string[]]$BaseOUs,
  [string]$GroupAll      = "AllEKKEmployees",
  [string]$GroupSystem   = "SystemMailUsers",
  [string]$GroupDisabled = "AllMailUsers_disabled",
  [switch]$Apply,
  [string]$OutDir        = "C:\AD-MailSync\output",
  [string]$LogDir        = "C:\AD-MailSync\Logs",
  [string]$ReportEmail   = "ictadmins@ekkanoo.com.bh",
  [string]$SmtpHost      = "172.17.0.141",
  [string]$FromEmail     = "ict.support@ekkorg.local"
)

$ErrorActionPreference = "Stop"

# ---------------- Logging ----------------
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile = Join-Path $LogDir ("AD_Mail_Sync_{0}.log" -f $stamp)

function Write-Log {
  param([string]$Message, [ValidateSet('INFO','WARN','ERROR','DBG')]$Level = 'INFO')
  $line = "[{0}] {1} {2}" -f (Get-Date -f 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
  Add-Content -Path $LogFile -Value $line
  Write-Host $line
}

function Rotate-Logs {
  param([string]$Folder, [int]$Days = 15)
  try {
    $cut   = (Get-Date).AddDays(-$Days)
    $old   = Get-ChildItem -Path $Folder -Filter "*.log" -File | Where-Object { $_.LastWriteTime -lt $cut }
    $count = 0
    foreach ($f in $old) { try { Remove-Item -LiteralPath $f.FullName -Force; $count++ } catch {} }
    if ($count -gt 0) { Write-Log ("Log rotation: removed {0} log(s) older than {1} days" -f $count, $Days) }
  } catch { Write-Log ("Log rotation error: {0}" -f $_.Exception.Message) "WARN" }
}

function Rotate-CSVs {
  param([string]$Folder, [int]$Keep = 10)
  try {
    if (-not (Test-Path $Folder)) { return }
    $patterns = @('AllEKKEmployees_*.csv', 'SystemMailUsers_*.csv', 'AllMailUsers_Disabled_*.csv')
    foreach ($pat in $patterns) {
      $files  = Get-ChildItem -Path $Folder -Filter $pat -File | Sort-Object LastWriteTime -Descending
      $excess = $files | Select-Object -Skip $Keep
      foreach ($f in $excess) { try { Remove-Item -LiteralPath $f.FullName -Force } catch {} }
      if ($excess) { Write-Log ("CSV rotation: removed {0} old file(s) for pattern {1}" -f $excess.Count, $pat) }
    }
  } catch { Write-Log ("CSV rotation error: {0}" -f $_.Exception.Message) "WARN" }
}

# ---------------- AD Module & DC selection ----------------
function Ensure-AD {
  try { Import-Module ActiveDirectory -ErrorAction Stop }
  catch { throw "ActiveDirectory module not found. Install RSAT AD Tools." }
}
Ensure-AD

if ([string]::IsNullOrWhiteSpace($Server)) {
  try {
    $dc     = Get-ADDomainController -Discover -Writable -ErrorAction Stop
    $Server = "$($dc.HostName)"
  } catch {
    $dc = Get-ADDomainController -Filter { IsReadOnly -eq $false } | Select-Object -First 1
    if (-not $dc) { throw "No writable DC found." }
    $Server = "$($dc.HostName)"
  }
}
$Server = [string]$Server
Write-Log "Using DC: $Server"

$ADParams = @{ Server = $Server }
if (Test-Path $CredPath) {
  try {
    $cred = Import-Clixml $CredPath
    if ($cred -and $cred.UserName) {
      $ADParams['Credential'] = $cred
      Write-Log "Loaded AD credential for $($cred.UserName)" "DBG"
    }
  } catch { Write-Log "WARN: Could not load cred from $CredPath. Continuing with current user." "WARN" }
}

# ---------------- Helpers ----------------
function Has-MailAddress($u) {
  if ($u.mail -and $u.mail -match '@') { return $true }
  if ($u.proxyAddresses) {
    foreach ($p in $u.proxyAddresses) { if ($p -match '^(?i)SMTP:' -and $p -match '@') { return $true } }
  }
  return $false
}

function Get-PrimarySmtpFromProxy($u) {
  if (-not $u.proxyAddresses) { return $null }
  foreach ($p in $u.proxyAddresses) {
    if ($p -match '^(?i)SMTP:') { return $p.Substring($p.IndexOf(':') + 1) }
  }
  return $null
}

function DomainPreferenceIndex([string]$email) {
  if ([string]::IsNullOrWhiteSpace($email)) { return 50 }
  $at = $email.IndexOf('@')
  if ($at -lt 0) { return 50 }
  $dom   = $email.Substring($at + 1).ToLower()
  $prefs = @('ekkorg.local', 'ekkanoo.com.bh', 'toyota.com.bh', 'lexus.com.bh', 'ban.red')
  $i     = $prefs.IndexOf($dom)
  if ($i -ge 0) { return $i } else { return 50 }
}

function Pick-BestAccount([object[]]$dupes) {
  $ranked = foreach ($u in $dupes) {
    $primary = Get-PrimarySmtpFromProxy $u
    $age     = try { [datetime]$u.whenChanged } catch { Get-Date "1900-01-01" }
    [pscustomobject]@{
      User    = $u
      HasMail = ([bool]$primary -or [bool]$u.mail)
      PrefIx  = (DomainPreferenceIndex ($(if ($primary) { $primary } else { $u.mail })))
      Age     = $age
    }
  }
  ($ranked | Sort-Object @{e='HasMail';Descending=$true}, @{e='PrefIx'}, @{e='Age';Descending=$true} | Select-Object -First 1).User
}

# ---------------- Export ----------------
function Do-Export {
  param([string]$Server, [string[]]$BaseOUs)
  Write-Log "Export process started."
  $props = @('mail','proxyAddresses','employeeID','enabled','whenChanged','division','distinguishedName','samAccountName','displayName')
  $all   = @()

  if ($BaseOUs -and $BaseOUs.Count -gt 0) {
    foreach ($sb in $BaseOUs) {
      $p = @{ SearchBase = $sb; LDAPFilter = "(&(objectCategory=person)(objectClass=user))"; Properties = $props; Server = $Server }
      if ($ADParams.ContainsKey('Credential')) { $p.Credential = $ADParams.Credential }
      $chunk = Get-ADUser @p -ErrorAction SilentlyContinue
      if ($chunk) { $all += $chunk }
      Write-Log "Queried OU: $sb (rows $($chunk.Count))"
    }
  } else {
    $p = @{ LDAPFilter = "(&(objectCategory=person)(objectClass=user))"; Properties = $props; Server = $Server }
    if ($ADParams.ContainsKey('Credential')) { $p.Credential = $ADParams.Credential }
    $all = Get-ADUser @p -ErrorAction SilentlyContinue
    Write-Log "Querying entire domain."
    Write-Log ("Initial query found {0} user objects." -f $all.Count)
  }

  $enabled  = $all | Where-Object { $_.Enabled -eq $true -and (Has-MailAddress $_) }
  $disabled = $all | Where-Object { $_.Enabled -ne $true -and (Has-MailAddress $_) }
  $system   = $enabled | Where-Object { -not ($_.employeeID -match '^\d+$') }

  function DivIsDomesticEmployees([string]$div) {
    if ([string]::IsNullOrWhiteSpace($div)) { return $false }
    ($div.ToLower() -replace '[ _]', '') -eq 'domesticemployees'
  }
  $eligible = $enabled | Where-Object { ($_.employeeID -match '^\d+$') -and -not (DivIsDomesticEmployees $_.division) }

  $final = New-Object System.Collections.Generic.List[object]
  ($eligible | Group-Object employeeID) | ForEach-Object {
    if ([string]::IsNullOrWhiteSpace($_.Name)) { return }
    if ($_.Count -eq 1) { [void]$final.Add($_.Group[0]) }
    else                { [void]$final.Add((Pick-BestAccount $_.Group)) }
  }

  if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
  $ts     = Get-Date -f 'yyyyMMdd-HHmm'
  $csvAll = Join-Path $OutDir ("AllEKKEmployees_{0}.csv"       -f $ts)
  $csvSys = Join-Path $OutDir ("SystemMailUsers_{0}.csv"       -f $ts)
  $csvDis = Join-Path $OutDir ("AllMailUsers_Disabled_{0}.csv" -f $ts)

  function ShapeRows($seq) {
    foreach ($x in $seq) {
      $primary = Get-PrimarySmtpFromProxy $x
      [pscustomobject]@{
        DistinguishedName = $x.DistinguishedName
        sAMAccountName    = $x.samAccountName
        DisplayName       = $x.DisplayName
        PrimarySMTP       = $(if ($primary) { $primary } else { $x.mail })
        EmployeeID        = $x.employeeID
        Enabled           = $x.Enabled
        Division          = $x.division
      }
    }
  }

  (ShapeRows $final)    | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csvAll
  (ShapeRows $system)   | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csvSys
  (ShapeRows $disabled) | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csvDis

  Write-Log "Export files created."
  Write-Log ("  AllEKKEmployees       : {0} (Rows: {1})" -f $csvAll, (Import-Csv $csvAll).Count)
  Write-Log ("  SystemMailUsers       : {0} (Rows: {1})" -f $csvSys, (Import-Csv $csvSys).Count)
  Write-Log ("  AllMailUsers_Disabled : {0} (Rows: {1})" -f $csvDis, (Import-Csv $csvDis).Count)
  Write-Log "Export DONE."

  Rotate-CSVs -Folder $OutDir -Keep 10

  $cntAll = (Import-Csv $csvAll).Count
  $cntSys = (Import-Csv $csvSys).Count
  $cntDis = (Import-Csv $csvDis).Count

  @{ All = $csvAll; System = $csvSys; Disabled = $csvDis
     CntAll = $cntAll; CntSys = $cntSys; CntDis = $cntDis }
}

# ---------------- Group Sync ----------------
function Do-GroupSync {
  param(
    [string]$GroupAll, [string]$GroupSystem, [string]$GroupDisabled,
    [hashtable]$CsvPaths, [string]$Server, [switch]$Apply
  )
  Write-Log "Group sync process started."

  foreach ($k in @('All','System','Disabled')) {
    if (-not ($CsvPaths.ContainsKey($k)) -or -not (Test-Path $CsvPaths[$k])) { throw "CSV not found: $($CsvPaths[$k])" }
  }

  Write-Log "DBG A1: reading CSVs"
  $allRows = Import-Csv $CsvPaths.All
  $sysRows = Import-Csv $CsvPaths.System
  $disRows = Import-Csv $CsvPaths.Disabled

  function ResolveDNs($rows) {
    $out = @()
    foreach ($r in $rows) {
      if ($r.DistinguishedName) { $out += $r.DistinguishedName; continue }
      if ($r.sAMAccountName) {
        $p = @{ Filter = "(samAccountName -eq '$($r.sAMAccountName)')"; Properties = 'distinguishedName'; Server = $Server }
        if ($ADParams.ContainsKey('Credential')) { $p.Credential = $ADParams.Credential }
        $u = Get-ADUser @p -ErrorAction SilentlyContinue
        if ($u) { $out += $u.DistinguishedName; continue }
      }
      if ($r.PrimarySMTP) {
        $p = @{ Filter = "(mail -eq '$($r.PrimarySMTP)')"; Properties = 'distinguishedName'; Server = $Server }
        if ($ADParams.ContainsKey('Credential')) { $p.Credential = $ADParams.Credential }
        $u = Get-ADUser @p -ErrorAction SilentlyContinue
        if ($u) { $out += $u.DistinguishedName; continue }
      }
    }
    $out | Sort-Object -Unique
  }

  Write-Log "DBG B1: ResolveDNs start"
  $desiredAll = ResolveDNs $allRows
  $desiredSys = ResolveDNs $sysRows
  $desiredDis = ResolveDNs $disRows
  Write-Log ("DBG B2: desired counts -> all={0}, sys={1}, dis={2}" -f $desiredAll.Count, $desiredSys.Count, $desiredDis.Count)

  function GetGroupDNs($g) {
    $grp  = Get-ADGroup @ADParams -Identity $g -ErrorAction Stop
    $ldap = "(memberOf:1.2.840.113556.1.4.1941:={0})" -f $grp.DistinguishedName
    $p    = @{ LDAPFilter = $ldap; Properties = 'distinguishedName'; Server = $Server }
    if ($ADParams.ContainsKey('Credential')) { $p.Credential = $ADParams.Credential }
    $users = Get-ADUser @p -ErrorAction SilentlyContinue | ForEach-Object { $_.DistinguishedName }
    if (-not $users) { $users = @() }
    $users
  }

  Write-Log "DBG C1: reading group members"
  $currentAll = GetGroupDNs $GroupAll
  $currentSys = GetGroupDNs $GroupSystem
  $currentDis = GetGroupDNs $GroupDisabled
  Write-Log ("DBG C2: current counts -> all={0}, sys={1}, dis={2}" -f $currentAll.Count, $currentSys.Count, $currentDis.Count)

  $addAll = $desiredAll | Where-Object { $_ -notin $currentAll }
  $addSys = $desiredSys | Where-Object { $_ -notin $currentSys }
  $addDis = $desiredDis | Where-Object { $_ -notin $currentDis }

  $extrasInAll  = $currentAll | Where-Object { $_ -notin $desiredAll }
  $moveAllToSys = @(); $moveAllToDis = @()
  foreach ($dn in $extrasInAll) {
    if ($dn -in $desiredSys)     { $moveAllToSys += $dn }
    elseif ($dn -in $desiredDis) { $moveAllToDis += $dn }
  }

  $plan = [pscustomobject]@{
    AddToAll         = $addAll
    AddToSystem      = $addSys
    AddToDisabled    = $addDis
    MoveFromAllToSys = $moveAllToSys
    MoveFromAllToDis = $moveAllToDis
  }
  Write-Log ("DBG D1: plan counts -> addAll={0}, addSys={1}, addDis={2}, moveAllToSys={3}, moveAllToDis={4}" -f `
    $plan.AddToAll.Count, $plan.AddToSystem.Count, $plan.AddToDisabled.Count, $plan.MoveFromAllToSys.Count, $plan.MoveFromAllToDis.Count)

  if (-not $Apply) { Write-Log "Plan only (no changes)."; return $plan }

  function Add-DNsToGroup([string]$g, [string[]]$dns) {
    if (-not $dns -or $dns.Count -eq 0) { return }
    try {
      Add-ADGroupMember @ADParams -Identity $g -Members $dns -ErrorAction Stop
      Write-Log ("Added {0} members to {1}" -f $dns.Count, $g)
    } catch {
      $msg = $_.Exception.Message
      Write-Log ("ERROR adding to {0}: {1}" -f $g, $msg) "ERROR"
      if ($msg -match 'Insufficient access rights') {
        Write-Log ("Hint: grant 'Write members' on '$g' to the task account.") "WARN"
      }
    }
  }

  Add-DNsToGroup $GroupAll      $plan.AddToAll
  Add-DNsToGroup $GroupSystem   $plan.AddToSystem
  Add-DNsToGroup $GroupDisabled $plan.AddToDisabled

  if ($plan.MoveFromAllToSys.Count -gt 0) {
    try { Remove-ADGroupMember @ADParams -Identity $GroupAll -Members $plan.MoveFromAllToSys -Confirm:$false -ErrorAction Stop }
    catch { Write-Log ("ERROR removing from {0}: {1}" -f $GroupAll, $_.Exception.Message) "ERROR" }
    Add-DNsToGroup $GroupSystem $plan.MoveFromAllToSys
  }
  if ($plan.MoveFromAllToDis.Count -gt 0) {
    try { Remove-ADGroupMember @ADParams -Identity $GroupAll -Members $plan.MoveFromAllToDis -Confirm:$false -ErrorAction Stop }
    catch { Write-Log ("ERROR removing from {0}: {1}" -f $GroupAll, $_.Exception.Message) "ERROR" }
    Add-DNsToGroup $GroupDisabled $plan.MoveFromAllToDis
  }

  Write-Log "Group sync DONE."
  $plan
}

# ---------------- HTML Email ----------------
function Build-HtmlReport {
  param([object]$Plan, [string]$Mode, [bool]$Failed = $false, [string]$ErrorMsg = "",
        [int]$CntAll = 0, [int]$CntSys = 0, [int]$CntDis = 0)

  $runDate = Get-Date -Format 'dd-MMM-yyyy HH:mm'

  if ($Failed) {
    return @"
<!DOCTYPE html><html><head><style>
body{font-family:Arial,sans-serif;font-size:13px;color:#333;margin:20px}
h2{color:#c0392b;border-bottom:2px solid #c0392b;padding-bottom:6px}
h3{color:#1a3a5c;margin-top:20px}
pre{background:#fff5f5;padding:12px;border-left:4px solid #c0392b;font-size:12px;white-space:pre-wrap}
p{margin:4px 0}.ft{font-size:11px;color:#888;margin-top:16px}
</style></head><body>
<h2>AD Mail Sync Report &mdash; FAILED</h2>
<p><b>Run Date:</b> $runDate</p>
<p><b>Domain Controller:</b> $Server</p>
<h3>Error Details</h3>
<pre>$([System.Security.SecurityElement]::Escape($ErrorMsg))</pre>
<p class='ft'>Log file attached &nbsp;&bull;&nbsp; Log directory: $LogDir</p>
</body></html>
"@
  }

  $addAll  = if ($Plan) { $Plan.AddToAll.Count }                                           else { 0 }
  $addSys  = if ($Plan) { $Plan.AddToSystem.Count + $Plan.MoveFromAllToSys.Count }         else { 0 }
  $addDis  = if ($Plan) { $Plan.AddToDisabled.Count + $Plan.MoveFromAllToDis.Count }       else { 0 }
  $remAll  = if ($Plan) { $Plan.MoveFromAllToSys.Count + $Plan.MoveFromAllToDis.Count }    else { 0 }
  $remSys  = 0
  $remDis  = 0
  $tAdd    = $addAll + $addSys + $addDis
  $tRem    = $remAll
  $grand   = $tAdd + $tRem

  function ca($n) { if ($n -gt 0) { "<span style='color:#27ae60;font-weight:bold'>$n</span>" } else { "<span style='color:#999'>0</span>" } }
  function cr($n) { if ($n -gt 0) { "<span style='color:#c0392b;font-weight:bold'>$n</span>" } else { "<span style='color:#999'>0</span>" } }

  $r1a=(ca $addAll); $r1r=(cr $remAll); $r1t=$addAll+$remAll
  $r2a=(ca $addSys); $r2r=(cr $remSys); $r2t=$addSys+$remSys
  $r3a=(ca $addDis); $r3r=(cr $remDis); $r3t=$addDis+$remDis
  $rTa=(ca $tAdd);   $rTr=(cr $tRem);   $rTt=$grand

  return @"
<!DOCTYPE html><html><head><style>
body{font-family:Arial,sans-serif;font-size:13px;color:#333;margin:20px}
h2{color:#1a3a5c;border-bottom:2px solid #1a3a5c;padding-bottom:6px}
h3{color:#1a3a5c;margin-top:20px}
p{margin:4px 0}
table{border-collapse:collapse;width:100%;margin-top:8px}
th{background-color:#1a3a5c;color:#fff;padding:8px 12px;text-align:left}
td{padding:7px 12px;border-bottom:1px solid #ddd}
tr:nth-child(even) td{background-color:#f4f7fb}
.tot td{font-weight:bold;background-color:#eaf2ff!important}
.ft{font-size:11px;color:#888;margin-top:16px}
</style></head><body>
<h2>AD Mail Sync Report</h2>
<p><b>Run Date:</b> $runDate</p>
<p><b>Domain Controller:</b> $Server</p>
<p><b>Mode:</b> $Mode</p>
<h3>Current Employee Counts</h3>
<table>
<tr><th>Group</th><th style='text-align:center'>Total Members</th></tr>
<tr><td>$GroupAll</td><td style='text-align:center;font-weight:bold;font-size:15px'>$CntAll</td></tr>
<tr><td>$GroupSystem</td><td style='text-align:center;font-weight:bold;font-size:15px'>$CntSys</td></tr>
<tr><td>$GroupDisabled</td><td style='text-align:center;font-weight:bold;font-size:15px'>$CntDis</td></tr>
</table>
<h3>Sync Summary (Changes This Run)</h3>
<table>
<tr><th>Group</th><th>Added</th><th>Removed</th><th>Total Changes</th></tr>
<tr><td>$GroupAll</td><td>$r1a</td><td>$r1r</td><td>$r1t</td></tr>
<tr><td>$GroupSystem</td><td>$r2a</td><td>$r2r</td><td>$r2t</td></tr>
<tr><td>$GroupDisabled</td><td>$r3a</td><td>$r3r</td><td>$r3t</td></tr>
<tr class='tot'><td><b>TOTAL</b></td><td><b>$rTa</b></td><td><b>$rTr</b></td><td><b>$rTt</b></td></tr>
</table>
<p class='ft'>Log file attached &nbsp;&bull;&nbsp; Log directory: $LogDir</p>
</body></html>
"@
}

function Send-SummaryMail {
  param([string]$HtmlBody, [string]$SubjectSuffix = "")
  try {
    $toList = @()
    if ($ReportEmail) { $toList += ($ReportEmail -split '[;, ]+' | Where-Object { $_ }) }

    $from = $FromEmail
    $smtp = $SmtpHost

    if (-not $toList -or [string]::IsNullOrWhiteSpace($from) -or [string]::IsNullOrWhiteSpace($smtp)) {
      Write-Log "WARN: email not sent (missing ReportEmail/FromEmail/SmtpHost)." "WARN"
      return
    }

    $runMode = if ($Apply) { 'APPLIED' } else { 'PLAN-ONLY' }
    $subject = "AD Mail Sync - $runMode - $(Get-Date -Format 'yyyy-MM-dd HH:mm')$SubjectSuffix"

    $mailParams = @{
      To         = $toList
      From       = $from
      Subject    = $subject
      SmtpServer = $smtp
      Body       = $HtmlBody
      BodyAsHtml = $true
      Attachments= $LogFile
    }

    Send-MailMessage @mailParams
    Write-Log ("Summary email sent via {0} to {1}" -f $smtp, ($toList -join ','))
  } catch {
    Write-Log ("WARN: email send failed: {0}" -f $_.Exception.Message) "WARN"
  }
}

# ---------------- Main flow ----------------
try {
  Rotate-Logs -Folder $LogDir -Days 15
  Write-Log "--- Starting AD Mail Sync ---"

  $csvs = Do-Export -Server $Server -BaseOUs $BaseOUs

  $plan = Do-GroupSync `
    -GroupAll      $GroupAll `
    -GroupSystem   $GroupSystem `
    -GroupDisabled $GroupDisabled `
    -CsvPaths      $csvs `
    -Server        $Server `
    -Apply:$Apply

  Write-Log "--- AD Mail Sync Finished Successfully ---"

  $mode    = if ($Apply) { 'APPLIED' } else { 'PLAN-ONLY' }
  $html    = Build-HtmlReport -Plan $plan -Mode $mode -CntAll $csvs.CntAll -CntSys $csvs.CntSys -CntDis $csvs.CntDis
  Send-SummaryMail -HtmlBody $html

  Write-Log "COMPLETED OK"
  exit 0

} catch {
  $errMsg = "{0}`r`nStack: {1}" -f $_.Exception.Message, $_.ScriptStackTrace
  Write-Log ("A critical error occurred: {0}" -f $_.Exception.Message) "ERROR"
  Write-Log ("Stack: {0}" -f $_.ScriptStackTrace) "ERROR"

  $errHtml = Build-HtmlReport -Failed $true -ErrorMsg $errMsg -Mode "N/A"
  Send-SummaryMail -HtmlBody $errHtml -SubjectSuffix " - FAILED"

  Write-Log "FAILED"
  exit 1
}
