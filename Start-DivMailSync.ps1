<#
.SYNOPSIS
    Master script — runs all AD-MailSync scripts sequentially,
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
    @{ File = "Sync-AllTSCEmployees.ps1";        Group = "TSC Division Group"                    }
    @{ File = "Sync-TSRAllEmployees.ps1";         Group = "TSR Department Group"                  }
    @{ File = "Sync-TSPAllEmployees.ps1";         Group = "TSP Division Group"                    }
    @{ File = "Sync-LogisticsAllEmployees.ps1";   Group = "Logistics Department Group"            }
    @{ File = "Sync-CRMEmployees.ps1";            Group = "CRM Division Group"                    }
    @{ File = "Sync-DensoEmployees.ps1";          Group = "Denso Service Centers Division Group"  }
    @{ File = "Sync-EKKTyresEmployees.ps1";       Group = "EK Kanoo Tyres Division Group"        }
)

$results    = @()
$syncData   = @()

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

    # Derive log prefix from script filename: strip "Sync-" prefix and ".ps1" suffix, append "_Sync_"
    $logPrefix = ($s.File -replace '^Sync-', '') -replace '\.ps1$', '_Sync_'

    # Parse added/removed counts from the log file written during this run
    $added = 0; $removed = 0
    $logFile = Get-ChildItem "$LogFolder\${logPrefix}*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $start } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($logFile) {
        $logContent = Get-Content $logFile.FullName -ErrorAction SilentlyContinue
        $addLine = $logContent | Where-Object { $_ -match '(ADDED successfully|Would be ADDED)\s*:\s*(\d+)' } | Select-Object -Last 1
        $remLine = $logContent | Where-Object { $_ -match '(REMOVED successfully|Would be REMOVED)\s*:\s*(\d+)' } | Select-Object -Last 1
        if ($addLine -match ':\s*(\d+)\s*$') { $added   = [int]$Matches[1] }
        if ($remLine -match ':\s*(\d+)\s*$') { $removed = [int]$Matches[1] }
    }

    $results  += [PSCustomObject]@{ Group = $s.Group; Script = $s.File; Status = $status; Duration = "${duration}s" }
    $syncData += [PSCustomObject]@{ Group = $s.Group; Added = $added; Removed = $removed }
}

# Also run Export-SyncReport.ps1 if it exists (keeps legacy CSV output intact)
if (Test-Path "$ScriptRoot\Export-SyncReport.ps1") {
    Write-Host "`n>>> Generating legacy sync report CSV..." -ForegroundColor Cyan
    & PowerShell.exe -ExecutionPolicy Bypass -NonInteractive -File "$ScriptRoot\Export-SyncReport.ps1"
}

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

$syncRows = $syncData | ForEach-Object {
    $cnt = if ($groupCounts.ContainsKey($_.Group)) { $groupCounts[$_.Group] } else { '-' }
    "<tr>
        <td>$($_.Group)</td>
        <td style='text-align:center;color:green'><b>$($_.Added)</b></td>
        <td style='text-align:center;color:red'><b>$($_.Removed)</b></td>
        <td style='text-align:center'><b>$($_.Added + $_.Removed)</b></td>
        <td style='text-align:center;font-weight:bold;font-size:15px'>$cnt</td>
    </tr>"
}

$totalAdded   = ($syncData | Measure-Object -Property Added   -Sum).Sum
$totalRemoved = ($syncData | Measure-Object -Property Removed -Sum).Sum
$totalMembers = ($groupCounts.Values | Where-Object { $_ -match '^\d+$' } | Measure-Object -Sum).Sum
$credNote     = if ($adUsername) { "Executed as: <b>$adUsername</b>" } else { "Executed as: <b>current session user</b>" }

$htmlBody = @"
<html><body style="font-family:Calibri,Arial,sans-serif;font-size:14px;color:#333">

<h2 style="color:#1a5276">AD Mail Group Sync Report</h2>
<p><b>Run Date:</b> $RunDate</p>
<p>$credNote</p>
<hr/>

<h3 style="color:#1a5276">Script Execution Summary</h3>
<table border="1" cellpadding="6" cellspacing="0" style="border-collapse:collapse;width:100%">
  <tr style="background:#1a5276;color:white">
    <th>Group</th><th>Script</th><th>Status</th><th>Duration</th>
  </tr>
  $($scriptRows -join "`n")
</table>

<br/>
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
