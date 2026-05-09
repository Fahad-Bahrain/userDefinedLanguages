param(
    [string]$PortalDir = "C:\AIX_Monitor\print_portal\print_portal"
)

$Branch  = "claude/add-working-directory-fV16R"
$BaseUrl = "https://raw.githubusercontent.com/fahad-bahrain/userdefinedlanguages/$Branch/print_portal"

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  EKK Print Portal - Applying Latest Updates" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

$files = @(
    @{ Url = "$BaseUrl/users.json";                   Dest = "$PortalDir\users.json" },
    @{ Url = "$BaseUrl/app.py";                       Dest = "$PortalDir\app.py" },
    @{ Url = "$BaseUrl/templates/dashboard.html";     Dest = "$PortalDir\templates\dashboard.html" }
)

foreach ($f in $files) {
    $name = Split-Path $f.Dest -Leaf
    Write-Host "`n  Downloading $name ..." -ForegroundColor Yellow
    try {
        Invoke-WebRequest $f.Url -OutFile $f.Dest -UseBasicParsing
        Write-Host "  [OK] $name" -ForegroundColor Green
    } catch {
        Write-Warning "Failed: $name - $_"
    }
}

Write-Host "`n  Verifying users.json..." -ForegroundColor Yellow
$check = python -c "import json; u=json.load(open(r'$PortalDir\users.json')); print('Azzat:', u['azzat']['prefixes'], '| Vipin:', u['vipin']['prefixes'])" 2>&1
Write-Host "  $check" -ForegroundColor White

Write-Host "`n  Restarting portal service..." -ForegroundColor Yellow
$svc = Get-Service | Where-Object { $_.DisplayName -match "print|portal|flask|aix" } | Select-Object -First 1
if ($svc) {
    Restart-Service $svc.Name -Force
    Write-Host "  [OK] Service restarted: $($svc.DisplayName)" -ForegroundColor Green
} else {
    Write-Warning "Service not found - restart the portal manually."
}

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Done! Log out and back in to see all changes." -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Cyan
