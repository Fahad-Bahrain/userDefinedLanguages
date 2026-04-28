#!/usr/bin/env python3
"""
Patch k-connect.py: move browse (...) buttons right next to their input fields.

Root cause: sections use s.columnconfigure(1, weight=1) which expands the
entry column to fill the full section width. The browse button sits in
column col*2+2 — which is then pushed to the far-right edge.

Fix: remove weight from entry columns and put it on an empty spacer column
placed after the browse button, so the button stays adjacent to the entry.

  Before: [label][<--- entry fills all space --->][button]
  After:  [label][entry][button][<--- spacer fills rest --->]
"""
import re, shutil, sys
from pathlib import Path

SRC = Path(r"C:\K-Connect-App\src\k-connect.py")
if not SRC.exists():
    sys.exit(f"[ERROR] Not found: {SRC}")

BAK = SRC.with_suffix(".py.bak5")
shutil.copy2(SRC, BAK)
print(f"[OK] Backup: {BAK}")

code = SRC.read_text(encoding="utf-8")

changed = 0

# ── A. Two-column sections on ONE line (inline partner form) ─────────────────
# s.columnconfigure(1, weight=1); s.columnconfigure(3, weight=1)
old = 's.columnconfigure(1, weight=1); s.columnconfigure(3, weight=1)'
new = 's.columnconfigure(1, weight=0); s.columnconfigure(3, weight=0); s.columnconfigure(5, weight=1)'
n = code.count(old)
code = code.replace(old, new)
changed += n
print(f"  [A] two-col same-line: {n} replacement(s)")

# ── B. Two-column sections on SEPARATE lines (PartnerDialog) ─────────────────
# s.columnconfigure(1, weight=1)
# s.columnconfigure(3, weight=1)
pat_b = re.compile(
    r'([ \t]*)s\.columnconfigure\(1, weight=1\)\n([ \t]*)s\.columnconfigure\(3, weight=1\)')
new_b = (r'\1s.columnconfigure(1, weight=0)\n'
         r'\2s.columnconfigure(3, weight=0); s.columnconfigure(5, weight=1)')
code, n = pat_b.subn(new_b, code)
changed += n
print(f"  [B] two-col multi-line: {n} replacement(s)")

# ── C. Single-column sections (Outbound / ACK / Inbound / PGP) ───────────────
# s.columnconfigure(1, weight=1)  — standalone after A & B already handled pairs
old_c = 's.columnconfigure(1, weight=1)'
new_c = 's.columnconfigure(1, weight=0); s.columnconfigure(3, weight=1)'
n = code.count(old_c)
code = code.replace(old_c, new_c)
changed += n
print(f"  [C] single-col: {n} replacement(s)")

if changed == 0:
    print("[WARN] No patterns matched — source may have changed already.")
else:
    SRC.write_text(code, encoding="utf-8")
    print(f"\n[OK] {changed} section(s) patched — browse buttons now sit next to entries.")

print()
print("Run the app to verify:")
print(r"  C:\K-Connect-App\venv\Scripts\python.exe C:\K-Connect-App\src\k-connect.py")
