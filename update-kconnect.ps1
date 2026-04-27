$src = "C:\K-Connect-App\src\k-connect.py"

if (-not (Test-Path $src)) {
    Write-Host "[ERROR] File not found: $src" -ForegroundColor Red
    exit 1
}

Copy-Item $src "$src.bak" -Force
Write-Host "[OK] Backup saved: $src.bak" -ForegroundColor Cyan

$c = Get-Content $src -Raw -Encoding UTF8

# ── 1. HEADER: bright cornflower blue (clearly lighter than navy) ──────────────
$c = $c -replace 'C_HEADER\s*=\s*"#[0-9a-fA-F]{6}"[^\n]*',
                 'C_HEADER  = "#2e86de"          # bright cornflower blue'

# ── 2. SUB-BAR: clear sky blue ────────────────────────────────────────────────
$c = $c -replace 'C_SUBBAR\s*=\s*"#[0-9a-fA-F]{6}"[^\n]*',
                 'C_SUBBAR  = "#54a0ff"          # sky blue'

# ── 3. AI WATERMARK: more visible nodes, lines, and text ──────────────────────
$c = $c -replace 'C_WM_NODE\s*=\s*"#[0-9a-fA-F]{6}"[^\n]*',
                 'C_WM_NODE = "#6aaed6"          # visible AI nodes'
$c = $c -replace 'C_WM_LINE\s*=\s*"#[0-9a-fA-F]{6}"[^\n]*',
                 'C_WM_LINE = "#90c4e8"          # visible AI connections'
$c = $c -replace 'C_WM_TEXT\s*=\s*"#[0-9a-fA-F]{6}"[^\n]*',
                 'C_WM_TEXT = "#78a8cc"          # visible AI text'
$c = $c -replace 'C_WM_DIM\s*=\s*"#[0-9a-fA-F]{6}"[^\n]*',
                 'C_WM_DIM  = "#9cc0e0"          # visible AI dim elements'

# ── 4. LOGIN DIALOG: hardcoded dark navy → light blue ─────────────────────────
$c = $c -replace 'self\.configure\(bg="#1a3a6b"\)',
                 'self.configure(bg="#2e86de")'

Set-Content $src -Value $c -Encoding UTF8

Write-Host ""
Write-Host "[OK] k-connect.py updated successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "──────────────────────────────────────────────────────" -ForegroundColor DarkCyan
Write-Host " To PREVIEW (run from Python source - no rebuild needed):" -ForegroundColor Yellow
Write-Host ""
Write-Host '   cd "C:\K-Connect-App\src"' -ForegroundColor White
Write-Host '   .venv\Scripts\python.exe k-connect.py' -ForegroundColor White
Write-Host ""
Write-Host " To REBUILD the exe after confirming it looks good:" -ForegroundColor Yellow
Write-Host '   Run your existing Nuitka build script' -ForegroundColor White
Write-Host "──────────────────────────────────────────────────────" -ForegroundColor DarkCyan
