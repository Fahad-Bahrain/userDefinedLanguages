#!/usr/bin/env python3
"""
Patch k-connect.py:
  - Dashboard uses Canvas as base so AI watermark is visible below content
  - Stat cards float on light-blue AI background (white cards on blue canvas)
  - Activity section gets a solid bordered box
  - inner frame sized naturally so canvas/watermark shows beneath it
"""
import shutil, sys
from pathlib import Path

SRC = Path(r"C:\K-Connect-App\src\k-connect.py")
if not SRC.exists():
    sys.exit(f"[ERROR] Not found: {SRC}")

BAK = SRC.with_suffix(".py.bak2")
shutil.copy2(SRC, BAK)
print(f"[OK] Backup saved: {BAK}")

code = SRC.read_text(encoding="utf-8")

# ── find method boundaries ────────────────────────────────────────────────────
START = "    def _build_dashboard_tab(self):\n"
END   = "    def _build_partners_tab(self):\n"
s = code.find(START)
e = code.find(END, s)
if s == -1 or e == -1:
    sys.exit("[ERROR] Cannot locate _build_dashboard_tab – was source changed?")

# ── replacement method ────────────────────────────────────────────────────────
NEW = '''    def _build_dashboard_tab(self):
        tab = self.tab_dash

        # Canvas IS the dashboard background – AI watermark drawn directly here
        self._dash_canvas = tk.Canvas(tab, bg=C_WM_BG1, highlightthickness=0)
        self._dash_canvas.pack(fill="both", expand=True)

        # Content block embedded as a canvas window.
        # Natural (not expand) height so the canvas/watermark shows below it.
        inner = tk.Frame(self._dash_canvas, bg=C_WM_BG1)
        _cid  = self._dash_canvas.create_window(0, 0, window=inner, anchor="nw")

        def _on_resize(e):
            if e.width < 2:
                return
            self._draw_watermark(self._dash_canvas, e.width, e.height)
            self._dash_canvas.itemconfig(_cid, width=e.width)

        self._dash_canvas.bind("<Configure>", _on_resize)

        # ── Stat cards ────────────────────────────────────────────────────────
        card_row = tk.Frame(inner, bg=C_WM_BG1)
        card_row.pack(fill="x", padx=10, pady=(12, 8))
        self._cards = {}
        for key, label, color, val in [
            ("partners", "Active Partners", C_BLUE,   "0"),
            ("sent",     "Files Sent",      C_GREEN,  "0"),
            ("received", "Files Received",  C_GOLD,   "0"),
            ("pending",  "Pending ACKs",    C_YELLOW, "0"),
            ("errors",   "Errors",          C_RED,    "0"),
        ]:
            cf = tk.Frame(card_row, bg=C_CARD,
                          highlightbackground=color,
                          highlightthickness=3, relief="flat", bd=0)
            cf.pack(side="left", expand=True, fill="both", padx=5)
            tk.Frame(cf, bg=color, height=4).pack(fill="x")
            lv = tk.Label(cf, text=val, bg=C_CARD, fg=color,
                          font=("Segoe UI", 26, "bold"))
            lv.pack(pady=(10, 0))
            tk.Label(cf, text=label, bg=C_CARD, fg=C_MUTED,
                     font=("Segoe UI", 8)).pack(pady=(0, 10))
            self._cards[key] = lv

        # ── Activity section – solid bordered box ─────────────────────────────
        tk.Label(inner, text="Recent Activity",
                 bg=C_WM_BG1, fg=C_HEADER,
                 font=("Segoe UI", 10, "bold")).pack(
            anchor="w", padx=14, pady=(4, 2))

        # Outer border frame (C_HEADER color = blue border)
        box = tk.Frame(inner, bg=C_HEADER, bd=0)
        box.pack(fill="x", padx=10, pady=(0, 10))

        # Inner white area
        tf = tk.Frame(box, bg=C_CARD)
        tf.pack(fill="both", expand=True, padx=1, pady=1)

        cols = ("time", "partner", "direction", "file", "status")
        style = ttk.Style()
        style.configure("Act.Treeview.Heading",
                        font=("Segoe UI", 9, "bold"),
                        background=C_HEADER, foreground="white")
        style.configure("Act.Treeview", font=("Segoe UI", 9),
                        rowheight=24, background=C_CARD)
        self.act_tree = ttk.Treeview(
            tf, columns=cols, show="headings",
            style="Act.Treeview", height=10,
            selectmode="browse")
        for col, w, lbl in [
            ("time",      60,  "Time"),
            ("partner",   90,  "Partner"),
            ("direction", 70,  "Direction"),
            ("file",      220, "File"),
            ("status",    90,  "Status")]:
            self.act_tree.heading(col, text=lbl)
            self.act_tree.column(col, width=w, anchor="w")
        vsb = ttk.Scrollbar(tf, orient="vertical",
                             command=self.act_tree.yview)
        self.act_tree.configure(yscrollcommand=vsb.set)
        self.act_tree.pack(side="left", fill="both", expand=True)
        vsb.pack(side="right", fill="y")
        self.act_tree.tag_configure("success", foreground=C_GREEN)
        self.act_tree.tag_configure("error",   foreground=C_RED)
        self.act_tree.tag_configure("warning", foreground=C_YELLOW)

'''

code = code[:s] + NEW + code[e:]
SRC.write_text(code, encoding="utf-8")

print("[OK] Dashboard patched successfully!")
print()
print("=" * 58)
print("  CORRECT command to run (uses main venv with PIL):")
print()
print(r'  C:\K-Connect-App\venv\Scripts\python.exe ^')
print(r'      C:\K-Connect-App\src\k-connect.py')
print()
print("  (the .venv inside src\ does NOT have PIL - that's")
print("   why the logo was missing)")
print("=" * 58)
