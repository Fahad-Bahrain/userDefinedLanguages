$src = "C:\K-Connect-App\src\k-connect.py"

if (-not (Test-Path $src)) {
    Write-Host "[ERROR] File not found: $src" -ForegroundColor Red
    exit 1
}

Copy-Item $src "$src.bak" -Force
Write-Host "[OK] Backup saved: $src.bak" -ForegroundColor Cyan

$c = Get-Content $src -Raw -Encoding UTF8

# ── 1. EKK Corporate Navy Blue header (matches logo) ──────────────────────────
$c = $c -replace 'C_HEADER\s*=\s*"#[0-9a-fA-F]{6}"[^\n]*',
                 'C_HEADER  = "#1a3a6e"          # EKK corporate navy blue'

# ── 2. Sub-bar: slightly lighter navy ─────────────────────────────────────────
$c = $c -replace 'C_SUBBAR\s*=\s*"#[0-9a-fA-F]{6}"[^\n]*',
                 'C_SUBBAR  = "#245090"          # EKK lighter navy'

# ── 3. Light backgrounds ───────────────────────────────────────────────────────
$c = $c -replace 'C_BG\s*=\s*"#[0-9a-fA-F]{6}"[^\n]*',
                 'C_BG      = "#f0f4fa"          # light blue-white'
$c = $c -replace 'C_SIDEBAR\s*=\s*"#[0-9a-fA-F]{6}"[^\n]*',
                 'C_SIDEBAR = "#eaf0fa"          # very light blue sidebar'
$c = $c -replace 'C_ROW_ALT\s*=\s*"#[0-9a-fA-F]{6}"[^\n]*',
                 'C_ROW_ALT = "#dce8f5"          # light blue table rows'

# ── 4. AI watermark palette (visible but subtle on light bg) ──────────────────
$c = $c -replace 'C_WM_BG1\s*=\s*"#[0-9a-fA-F]{6}"[^\n]*',
                 'C_WM_BG1  = "#eaf2fb"          # AI watermark bg'
$c = $c -replace 'C_WM_BG2\s*=\s*"#[0-9a-fA-F]{6}"[^\n]*',
                 'C_WM_BG2  = "#dceaf6"          # AI watermark bg2'
$c = $c -replace 'C_WM_NODE\s*=\s*"#[0-9a-fA-F]{6}"[^\n]*',
                 'C_WM_NODE = "#7aaed6"          # AI node colour'
$c = $c -replace 'C_WM_LINE\s*=\s*"#[0-9a-fA-F]{6}"[^\n]*',
                 'C_WM_LINE = "#9cc4e0"          # AI connection lines'
$c = $c -replace 'C_WM_TEXT\s*=\s*"#[0-9a-fA-F]{6}"[^\n]*',
                 'C_WM_TEXT = "#88aece"          # AI keyword text'
$c = $c -replace 'C_WM_DIM\s*=\s*"#[0-9a-fA-F]{6}"[^\n]*',
                 'C_WM_DIM  = "#a8c8e4"          # AI dim elements'

# ── 5. LIVE LOG: lighten from pitch-black to dark navy ────────────────────────
# strip bg + scrolledtext bg
$c = $c -replace '"#0d1117"', '"#1a2d4a"'
# header bar inside live log
$c = $c -replace '"#161b22"', '"#1e3a5e"'
# LIVE LOG text foreground (brighter on dark navy)
$c = $c -replace '"#c9d1d9"', '"#d0e8f8"'
# muted log text colour
$c = $c -replace '"#8b949e"', '"#7ab0d8"'

# ── 6. Footer bar: dark navy (not pitch black) ─────────────────────────────────
$c = $c -replace '"#1a2133"', '"#152540"'

# ── 7. Login dialog bg: back to EKK corporate navy ────────────────────────────
$c = $c -replace 'self\.configure\(bg="#[0-9a-fA-F]{6}"\)',
                 'self.configure(bg="#1a3a6e")'

Set-Content $src -Value $c -Encoding UTF8

Write-Host ""
Write-Host "[OK] EKK corporate colours applied!" -ForegroundColor Green
Write-Host ""
Write-Host "Changes:" -ForegroundColor Yellow
Write-Host "  Header    : EKK navy blue  #1a3a6e" -ForegroundColor White
Write-Host "  Sub-bar   : lighter navy   #245090" -ForegroundColor White
Write-Host "  Background: light blue-white         " -ForegroundColor White
Write-Host "  Live Log  : dark navy (not black)    " -ForegroundColor White
Write-Host "  AI theme  : visible watermark colours" -ForegroundColor White
Write-Host ""
Write-Host "Run:" -ForegroundColor Yellow
Write-Host '  C:\K-Connect-App\venv\Scripts\python.exe C:\K-Connect-App\src\k-connect.py' -ForegroundColor White
