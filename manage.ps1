param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("start","stop","status")]
    [string]$Action
)

$AppDir  = "C:\sms\EKK_Alert_SMS_Gateway"
$AppFile = "app.py"
$Port    = 5050
$LogFile = "$AppDir\app.log"

function Get-AppProcess {
    Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq "Listen" } |
        Select-Object -First 1 |
        ForEach-Object { Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue }
}

switch ($Action) {

    "start" {
        $proc = Get-AppProcess
        if ($proc) {
            Write-Host "[INFO] App is already running (PID $($proc.Id))" -ForegroundColor Yellow
        } else {
            Write-Host "[INFO] Starting EKK Alert SMS Gateway on port $Port ..." -ForegroundColor Cyan
            Start-Process -FilePath "python" `
                          -ArgumentList $AppFile `
                          -WorkingDirectory $AppDir `
                          -RedirectStandardOutput $LogFile `
                          -RedirectStandardError "$AppDir\app-error.log" `
                          -WindowStyle Hidden
            Start-Sleep -Seconds 3
            $proc = Get-AppProcess
            if ($proc) {
                Write-Host "[OK] Started successfully (PID $($proc.Id))" -ForegroundColor Green
                Write-Host "     URL: http://127.0.0.1:$Port" -ForegroundColor Green
            } else {
                Write-Host "[ERROR] Failed to start. Check $AppDir\app-error.log" -ForegroundColor Red
            }
        }
    }

    "stop" {
        $proc = Get-AppProcess
        if ($proc) {
            Write-Host "[INFO] Stopping PID $($proc.Id) ..." -ForegroundColor Cyan
            Stop-Process -Id $proc.Id -Force
            Write-Host "[OK] Stopped." -ForegroundColor Green
        } else {
            Write-Host "[INFO] App is not running on port $Port." -ForegroundColor Yellow
        }
    }

    "status" {
        $proc = Get-AppProcess
        if ($proc) {
            Write-Host "[RUNNING] EKK Alert SMS Gateway" -ForegroundColor Green
            Write-Host "  PID  : $($proc.Id)"
            Write-Host "  Port : $Port"
            Write-Host "  URL  : http://127.0.0.1:$Port"
            Write-Host "  Log  : $LogFile"
        } else {
            Write-Host "[STOPPED] App is not running on port $Port." -ForegroundColor Red
        }
    }
}
