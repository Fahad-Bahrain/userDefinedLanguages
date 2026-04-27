#!/usr/bin/env python3
"""
Patch k-connect.py: fix form entry fields to ~half width.
Changes sticky="ew" to sticky="w" on Entry .grid() calls in form helpers,
and increases default widths so paths are still readable.
"""
import re, shutil, sys
from pathlib import Path

SRC = Path(r"C:\K-Connect-App\src\k-connect.py")
if not SRC.exists():
    sys.exit(f"[ERROR] Not found: {SRC}")

BAK = SRC.with_suffix(".py.bak3")
shutil.copy2(SRC, BAK)
print(f"[OK] Backup: {BAK}")

code = SRC.read_text(encoding="utf-8")

# ── 1. row() in _build_inline_partner_form  (par, width=38) ──────────────────
# Entry grid spans two lines: e.grid(row=r, column=col * 2 + 1,\n  sticky="ew"
code = code.replace(
    'def row(par, label, var, r, col=0, width=38, show=None):',
    'def row(par, label, var, r, col=0, width=55, show=None):')

# ── 2. row() in PartnerDialog  (parent, width=35) ────────────────────────────
code = code.replace(
    'def row(parent, label, var, r, col=0, width=35, show=None):',
    'def row(parent, label, var, r, col=0, width=50, show=None):')

# ── 3. srow() in _build_settings_tab  (width=30) ─────────────────────────────
code = code.replace(
    'def srow(parent, label, var, r, width=30, show=None):',
    'def srow(parent, label, var, r, width=45, show=None):')

# ── 4. ent() in RouteEditorDialog  (width=34) ─────────────────────────────────
code = code.replace(
    'def ent(var, row, width=34, show=None):',
    'def ent(var, row, width=48, show=None):')

# ── 5. Remove horizontal stretch from Entry .grid() calls in form helpers ────
# Pattern A: two-line grid call  e.grid(row=r, column=col * 2 + 1,\n  sticky="ew"
code = re.sub(
    r'(e\.grid\(row=r, column=col \* 2 \+ 1,\s+)sticky="ew"',
    r'\1sticky="w"',
    code)

# Pattern B: one-line grid – settings srow  e.grid(row=r, column=1, sticky="ew", padx=6
code = code.replace(
    'e.grid(row=r, column=1, sticky="ew", padx=6, pady=4)',
    'e.grid(row=r, column=1, sticky="w",  padx=6, pady=4)')

# Pattern C: RouteEditorDialog ent()  sticky="ew", padx=8
code = code.replace(
    'e.grid(row=row, column=1, sticky="ew", padx=8, pady=6)',
    'e.grid(row=row, column=1, sticky="w",  padx=8, pady=6)')

SRC.write_text(code, encoding="utf-8")

print("[OK] Form field widths patched!")
print()
print("Changes applied:")
print("  row() inline partner form : width 38 -> 55 chars, no stretch")
print("  row() PartnerDialog       : width 35 -> 50 chars, no stretch")
print("  srow() Settings           : width 30 -> 45 chars, no stretch")
print("  ent()  RouteEditor        : width 34 -> 48 chars, no stretch")
print()
print("Run:")
print(r"  C:\K-Connect-App\venv\Scripts\python.exe C:\K-Connect-App\src\k-connect.py")
