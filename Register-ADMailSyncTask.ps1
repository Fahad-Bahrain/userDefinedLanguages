<#
.SYNOPSIS
    Registers both AD Mail Sync scheduled tasks on this machine.
    Matches the schedule from the source PC:
      - AD Mail Sync (Silent)            : 11:30 PM daily  — ad-sync_silent.ps1
      - AD-MailSync - Master Sync Report : 11:45 PM daily  — Start-DivMailSync.ps1

.PARAMETER RunAsUser
    Domain account that will run both tasks.
    Example: ekkorg\svc-mailsync  or  ekkorg\ict.support

.PARAMETER ScriptRoot
    Folder containing the scripts. Default: C:\AD-MailSync

.EXAMPLE
    # Interactive — prompts for password
    PowerShell -ExecutionPolicy Bypass -File .\Register-ADMailSyncTask.ps1 -RunAsUser "ekkorg\svc-mailsync"

    # Fully silent (supply password via parameter — use only on secure console)
    PowerShell -ExecutionPolicy Bypass -File .\Register-ADMailSyncTask.ps1 -RunAsUser "ekkorg\svc-mailsync" -RunAsPassword "P@ssword"
#>

param(
    [string]$RunAsUser,
    [string]$RunAsPassword,
    [string]$ScriptRoot = "C:\AD-MailSync"
)

# ── Require elevation ─────────────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]"Administrator")) {
    Write-Warning "Run this script as Administrator."
    exit 1
}

# ── Collect run-as account ────────────────────────────────────────────────────
if (-not $RunAsUser) {
    Write-Host ""
    Write-Host "  Enter the service account that will run the scheduled tasks." -ForegroundColor Cyan
    Write-Host "  Example: ekkorg\svc-mailsync  or  EKKORG\ict.support" -ForegroundColor Yellow
    Write-Host ""
    $RunAsUser = Read-Host "  Run-as account"
}

if (-not $RunAsPassword) {
    $secPwd        = Read-Host "  Password for $RunAsUser" -AsSecureString
    $RunAsPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPwd))
}

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  Registering AD Mail Sync Scheduled Tasks" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan

# ── Task definitions ──────────────────────────────────────────────────────────
$tasks = @(
    @{
        Name        = "AD Mail Sync (Silent)"
        Description = "Exports AD mail users and syncs AllEKKEmployees, SystemMailUsers, AllMailUsers_Disabled groups. Sends HTML summary email."
        Script      = "ad-sync_silent_PATCHED.ps1"
        Arguments   = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptRoot\ad-sync_silent_PATCHED.ps1`" -Apply -CredPath `"$ScriptRoot\cred.xml`" -LogDir `"$ScriptRoot\Logs`""
        TriggerTime = "23:30"
    },
    @{
        Name        = "AD-MailSync - Master Sync & Report"
        Description = "Runs all Division Group sync scripts (TSC, TSR, TSP, Logistics) and sends HTML summary email."
        Script      = "Start-DivMailSync.ps1"
        Arguments   = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptRoot\Start-DivMailSync.ps1`""
        TriggerTime = "23:45"
    }
)

# ── Register each task ────────────────────────────────────────────────────────
foreach ($t in $tasks) {

    $scriptPath = Join-Path $ScriptRoot $t.Script
    if (-not (Test-Path $scriptPath)) {
        Write-Warning "Script not found, skipping: $scriptPath"
        continue
    }

    # Remove existing task if present
    if (Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $t.Name -Confirm:$false
        Write-Host "  Removed existing task: $($t.Name)" -ForegroundColor DarkGray
    }

    $action  = New-ScheduledTaskAction `
                   -Execute  "powershell.exe" `
                   -Argument $t.Arguments `
                   -WorkingDirectory $ScriptRoot

    $trigger = New-ScheduledTaskTrigger -Daily -At $t.TriggerTime

    $settings = New-ScheduledTaskSettingsSet `
                    -ExecutionTimeLimit    (New-TimeSpan -Hours 2) `
                    -StartWhenAvailable `
                    -MultipleInstances     IgnoreNew `
                    -RunOnlyIfNetworkAvailable

    $principal = New-ScheduledTaskPrincipal `
                     -UserId   $RunAsUser `
                     -LogonType Password `
                     -RunLevel Highest

    Register-ScheduledTask `
        -TaskName   $t.Name `
        -Description $t.Description `
        -Action     $action `
        -Trigger    $trigger `
        -Settings   $settings `
        -Principal  $principal `
        -Password   $RunAsPassword `
        -Force | Out-Null

    Write-Host "  [OK] Registered : $($t.Name)" -ForegroundColor Green
    Write-Host "       Runs at    : $($t.TriggerTime) daily" -ForegroundColor White
    Write-Host "       Script     : $scriptPath" -ForegroundColor White
    Write-Host ""
}

# ── Also save cred.xml for the run-as account (needed by ad-sync_silent.ps1) ──
Write-Host "  Saving cred.xml for ad-sync_silent.ps1..." -ForegroundColor Cyan
$secPwdObj = ConvertTo-SecureString $RunAsPassword -AsPlainText -Force
$credObj   = New-Object System.Management.Automation.PSCredential($RunAsUser, $secPwdObj)
$credObj   | Export-Clixml -Path (Join-Path $ScriptRoot "cred.xml")
Write-Host "  [OK] cred.xml saved (encrypted for this machine/account)." -ForegroundColor Green

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  All tasks registered successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "  Verify in Task Scheduler:" -ForegroundColor White
Write-Host "    Get-ScheduledTask | Where Name -match 'AD Mail'" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Test run immediately:" -ForegroundColor White
Write-Host "    Start-ScheduledTask 'AD Mail Sync (Silent)'" -ForegroundColor Yellow
Write-Host "    Start-ScheduledTask 'AD-MailSync - Master Sync & Report'" -ForegroundColor Yellow
Write-Host "=====================================================" -ForegroundColor Cyan
