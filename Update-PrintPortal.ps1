<#
.SYNOPSIS
    Downloads and applies the latest print_portal files from GitHub.
    Run this script as Administrator from any location.
#>

$PortalDir = "C:\AIX_Monitor\print_portal\print_portal"
$Branch    = "claude/add-working-directory-fV16R"
$BaseUrl   = "https://raw.githubusercontent.com/fahad-bahrain/userdefinedlanguages/$Branch/print_portal"

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  EKK Print Portal - Applying Latest Updates" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# ── 1. Fix users.json directly (no download needed) ──────────────────────────
Write-Host "`n  [1/3] Writing users.json..." -ForegroundColor Yellow

$usersJson = @'
{
  "ict": {
    "password": "ictprt@2026",
    "name": "ICT Admin",
    "role": "admin",
    "prefixes": []
  },
  "anoop": {
    "password": "Anoop@123",
    "name": "Anoop",
    "role": "user",
    "prefixes": ["TSC", "TBSC"]
  },
  "rakesh": {
    "password": "Rakesh@123",
    "name": "Rakesh",
    "role": "user",
    "prefixes": ["TSC", "TBSC"]
  },
  "vipin": {
    "password": "Vipin@123",
    "name": "Vipin",
    "role": "user",
    "prefixes": ["TP", "MCSR", "MCP"]
  },
  "vimala": {
    "password": "Vimala@123",
    "name": "Vimala",
    "role": "user",
    "prefixes": ["MCS"]
  },
  "azzat": {
    "password": "Azzat@123",
    "name": "Azzat",
    "role": "user",
    "prefixes": ["DEN", "KBSC"]
  }
}
'@

[System.IO.File]::WriteAllText("$PortalDir\users.json", $usersJson, [System.Text.Encoding]::UTF8)
Write-Host "  [OK] users.json written." -ForegroundColor Green

# Verify
$check = python -c "import json; u=json.load(open(r'$PortalDir\users.json')); print(u['azzat']['prefixes'])" 2>&1
Write-Host "       Azzat prefixes: $check" -ForegroundColor White

# ── 2. Download latest app.py ─────────────────────────────────────────────────
Write-Host "`n  [2/3] Downloading app.py..." -ForegroundColor Yellow
try {
    Invoke-WebRequest "$BaseUrl/app.py" -OutFile "$PortalDir\app.py" -UseBasicParsing
    Write-Host "  [OK] app.py updated." -ForegroundColor Green
} catch {
    Write-Warning "Failed to download app.py: $_"
}

# ── 3. Download latest dashboard.html ────────────────────────────────────────
Write-Host "`n  [3/3] Downloading dashboard.html..." -ForegroundColor Yellow
try {
    Invoke-WebRequest "$BaseUrl/templates/dashboard.html" -OutFile "$PortalDir\templates\dashboard.html" -UseBasicParsing
    Write-Host "  [OK] dashboard.html updated." -ForegroundColor Green
} catch {
    Write-Warning "Failed to download dashboard.html: $_"
}

# ── 4. Restart the portal service ─────────────────────────────────────────────
Write-Host "`n  Restarting print portal service..." -ForegroundColor Yellow
$svc = Get-Service | Where-Object { $_.DisplayName -match "print|portal|flask|aix" } | Select-Object -First 1
if ($svc) {
    Restart-Service $svc.Name -Force
    Write-Host "  [OK] Service '$($svc.DisplayName)' restarted." -ForegroundColor Green
} else {
    Write-Warning "Service not found — please restart the portal manually."
}

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Done! Log out and back in to see all changes." -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Cyan
