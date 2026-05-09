<#
.SYNOPSIS
    Master script — runs all 4 AD-MailSync scripts sequentially,
    generates sync summary, and sends HTML summary email.

.PARAMETER UseCredential
    Prompt for AD credentials once and pass them to all sub-scripts.
    Use this when running from a non-privileged account.

.PARAMETER Test
    Passes -Test (dry-run) to all sub-scripts. No AD changes will be made.

.EXAMPLE
    # Normal live run with alternate credentials
    PowerShell -ExecutionPolicy Bypass -File .\Start-DivMailSync.ps1 -UseCredential

    # Dry-run to preview changes only
    PowerShell -ExecutionPolicy Bypass -File .\Start-DivMailSync.ps1 -UseCredential -Test
#>

param(
    [switch]$UseCredential,
    [switch]$Test
)

# ── Email Settings ────────────────────────────────────────────────────────────
$SMTPServer = "mail.ekkanoo.com.bh"
$SMTPPort   = 25
$MailFrom   = "ict.support@ekkanoo.com.bh"
$MailTo     = "ictadmins@ekkanoo.com.bh"
$MailCC     = @()
$SMTPUser   = ""
$SMTPPass   = ""
# ─────────────────────────────────────────────────────────────────────────────

$ScriptRoot   = "C:\AD-MailSync"
$ReportFolder = "C:\AD-MailSync\Reports"
$LogFolder    = "C:\AD-MailSync\Logs"
$RunDate      = Get-Date -Format "dd-MMM-yyyy HH:mm"

if (-not (Test-Path $ReportFolder)) { New-Item -ItemType Directory -Path $ReportFolder | Out-Null }

# ------------------------------------------------------------------------------
#  COLLECT CREDENTIALS ONCE (if -UseCredential specified)
# ------------------------------------------------------------------------------

$adUsername = ""
$adPassword = ""

if ($UseCredential) {
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "  Enter AD credentials with Write permission on all Division Groups" -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""

    $adCred = Get-Credential -Message "Enter AD account (e.g. ekkorg\ict.support)"
    if (-not $adCred) { Write-Warning "No credentials supplied. Exiting."; exit 1 }

    $adUsername = $adCred.UserName
    $adPassword = $adCred.Password | ConvertFrom-SecureString

    Write-Host ""
    Write-Host "  Credentials accepted for: $adUsername" -ForegroundColor Green
    Write-Host ""
}

# ------------------------------------------------------------------------------
#  SCRIPTS TO RUN IN ORDER
# ------------------------------------------------------------------------------

$scripts = @(
    @{ File = "Sync-AllTSCEmployees.ps1";        Group = "TSC Division Group"         }
    @{ File = "Sync-TSRAllEmployees.ps1";         Group = "TSR Department Group"       }
    @{ File = "Sync-TSPAllEmployees.ps1";         Group = "TSP Division Group"         }
    @{ File = "Sync-LogisticsAllEmployees.ps1";   Group = "Logistics Department Group" }
)

$results = @()

# ------------------------------------------------------------------------------
#  RUN EACH SYNC SCRIPT
# ------------------------------------------------------------------------------

foreach ($s in $scripts) {
    $filePath = Join-Path $ScriptRoot $s.File
    Write-Host "`n>>> Running: $($s.File)" -ForegroundColor Cyan

    $start = Get-Date

    $argList = @("-ExecutionPolicy", "Bypass", "-NonInteractive", "-File", "`"$filePath`"")
    if ($Test)       { $argList += "-Test" }
    if ($adUsername) { $argList += "-ADUsername"; $argList += "`"$adUsername`"" }
    if ($adPassword) { $argList += "-ADPassword"; $argList += "`"$adPassword`"" }

    try {
        & PowerShell.exe @argList
        $status = if ($LASTEXITCODE -eq 0) { "SUCCESS" } else { "WARNING" }
    } catch {
        $status = "FAILED"
        Write-Warning "Error running $($s.File): $_"
    }

    $duration = [math]::Round(((Get-Date) - $start).TotalSeconds)

    $results += [PSCustomObject]@{
        Group    = $s.Group
        Script   = $s.File
        Status   = $status
        Duration = "${duration}s"
    }
}

# ------------------------------------------------------------------------------
#  GENERATE CSV REPORT (used to build sync summary table)
# ------------------------------------------------------------------------------

Write-Host "`n>>> Generating sync report..." -ForegroundColor Cyan
& PowerShell.exe -ExecutionPolicy Bypass -NonInteractive -File "$ScriptRoot\Export-SyncReport.ps1"

$summaryCSV  = Get-ChildItem "$ReportFolder\SyncSummary_*.csv" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$summaryData = if ($summaryCSV) { Import-Csv $summaryCSV.FullName } else { @() }

# Get current member counts for each division group from AD
$groupCounts = @{}
try {
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
    foreach ($s in $scripts) {
        try {
            $grp = Get-ADGroup -Identity $s.Group -Properties member -ErrorAction Stop
            $groupCounts[$s.Group] = $grp.member.Count
        } catch {
            $groupCounts[$s.Group] = "N/A"
        }
    }
} catch { }

# ------------------------------------------------------------------------------
#  BUILD HTML EMAIL
# ------------------------------------------------------------------------------

$scriptRows = $results | ForEach-Object {
    $color = switch ($_.Status) {
        "SUCCESS" { "#d4edda" }
        "WARNING" { "#fff3cd" }
        "FAILED"  { "#f8d7da" }
    }
    "<tr style='background:$color'>
        <td>$($_.Group)</td>
        <td>$($_.Script)</td>
        <td><b>$($_.Status)</b></td>
        <td>$($_.Duration)</td>
    </tr>"
}

$syncRows = $summaryData | ForEach-Object {
    $cnt = if ($groupCounts.ContainsKey($_.Group)) { $groupCounts[$_.Group] } else { '-' }
    "<tr>
        <td>$($_.Group)</td>
        <td style='text-align:center;color:green'><b>$($_.Added)</b></td>
        <td style='text-align:center;color:red'><b>$($_.Removed)</b></td>
        <td style='text-align:center'><b>$($_.TotalChange)</b></td>
        <td style='text-align:center;font-weight:bold;font-size:15px'>$cnt</td>
    </tr>"
}

$totalAdded   = ($summaryData | Measure-Object -Property Added   -Sum).Sum
$totalRemoved = ($summaryData | Measure-Object -Property Removed -Sum).Sum
$totalMembers = ($groupCounts.Values | Where-Object { $_ -match '^\d+$' } | Measure-Object -Sum).Sum
$credNote     = if ($adUsername) { "Executed as: <b>$adUsername</b>" } else { "Executed as: <b>current session user</b>" }

$htmlBody = @"
<html><body style="font-family:Calibri,Arial,sans-serif;font-size:14px;color:#333">

<h2 style="color:#1a5276">AD Mail Group Sync Report</h2>
<p><b>Run Date:</b> $RunDate</p>
<p>$credNote</p>
<hr/>

<h3 style="color:#1a5276">Sync Summary</h3>
<table border="1" cellpadding="6" cellspacing="0" style="border-collapse:collapse;width:100%">
  <tr style="background:#1a5276;color:white">
    <th>Group</th><th>Added</th><th>Removed</th><th>Total Changes</th><th>Current Members</th>
  </tr>
  $($syncRows -join "`n")
  <tr style="background:#eaf2ff;font-weight:bold">
    <td>TOTAL</td>
    <td style="text-align:center;color:green">$totalAdded</td>
    <td style="text-align:center;color:red">$totalRemoved</td>
    <td style="text-align:center">$($totalAdded + $totalRemoved)</td>
    <td style="text-align:center;font-size:15px">$totalMembers</td>
  </tr>
</table>

<br/>
<p style="color:#888;font-size:12px">Log files: $LogFolder</p>

</body></html>
"@

# ------------------------------------------------------------------------------
#  SEND EMAIL  (no attachments — body contains full summary)
# ------------------------------------------------------------------------------

Write-Host "`n>>> Sending email report..." -ForegroundColor Cyan

$mailParams = @{
    SmtpServer = $SMTPServer
    Port       = $SMTPPort
    From       = $MailFrom
    To         = $MailTo
    Subject    = "AD Mail Group Sync Report - $RunDate"
    Body       = $htmlBody
    BodyAsHtml = $true
    Encoding   = [System.Text.Encoding]::UTF8
}

if ($MailCC)  { $mailParams.CC = $MailCC }
if ($SMTPUser -and $SMTPPass) {
    $secPass               = ConvertTo-SecureString $SMTPPass -AsPlainText -Force
    $mailParams.Credential = New-Object System.Management.Automation.PSCredential($SMTPUser, $secPass)
}

try {
    Send-MailMessage @mailParams
    Write-Host "Email sent successfully to: $MailTo" -ForegroundColor Green
} catch {
    Write-Warning "Failed to send email: $_"
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  ALL DONE  $RunDate" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
$results | Format-Table -AutoSize
