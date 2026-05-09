from flask import Flask, render_template, request, redirect, url_for, session, jsonify, send_file
from functools import wraps
import paramiko
import pandas as pd
import json
import os
import re

app = Flask(__name__)
app.secret_key = 'ekk-print-portal-2024-x9k2m'

AIX_HOST = "ekkhp01a"
AIX_USER = "printm"
AIX_PASS = "printm"
AIX_PORT = 22

APP_VERSION = "v2.0"

# print_portal\ lives inside C:\AIX_Monitor\
BASE_DIR   = os.path.dirname(os.path.abspath(__file__))
PARENT_DIR = os.path.dirname(BASE_DIR)
USERS_FILE    = os.path.join(BASE_DIR, "users.json")
OVERRIDE_FILE = os.path.join(BASE_DIR, "printers_override.json")


def _find_file(*names):
    """Search BASE_DIR then PARENT_DIR for the first matching filename."""
    for folder in (BASE_DIR, PARENT_DIR):
        for name in names:
            p = os.path.join(folder, name)
            if os.path.exists(p):
                return p
    return None

EXCEL_FILE = _find_file("Oracle_printers.xlsx", "Oracle_Printers.xlsx") \
             or os.path.join(PARENT_DIR, "Oracle_printers.xlsx")


# ── Data helpers ──────────────────────────────────────────────────────────────

def load_users():
    with open(USERS_FILE, encoding="utf-8") as f:
        return json.load(f)


def save_users(users):
    with open(USERS_FILE, "w", encoding="utf-8") as f:
        json.dump(users, f, indent=2)


def load_override():
    if not os.path.exists(OVERRIDE_FILE):
        return {"added": [], "edited": {}, "deleted": [], "ignored": []}
    with open(OVERRIDE_FILE, encoding="utf-8") as f:
        data = json.load(f)
    data.setdefault("added",   [])
    data.setdefault("edited",  {})
    data.setdefault("deleted", [])
    data.setdefault("ignored", [])
    return data


def save_override(data):
    with open(OVERRIDE_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)


def load_printers():
    override = load_override()
    deleted  = set(override["deleted"])
    edited   = override["edited"]

    printers    = []
    seen_queues = set()

    if os.path.exists(EXCEL_FILE):
        df = pd.read_excel(EXCEL_FILE)
        df.columns = [c.strip() for c in df.columns]
        for _, row in df.iterrows():
            ip    = str(row.get("IP Address", "")).strip()
            queue = str(row.get("Printer Queue Name", "")).strip()
            if ip and queue and ip != "nan" and queue != "nan":
                if queue not in deleted:
                    if queue in edited:
                        ip = edited[queue].get("ip", ip)
                    printers.append({"ip": ip, "queue": queue})
                    seen_queues.add(queue)

    # Admin-added printers not in Excel
    ignored = set(override["ignored"])
    for p in override["added"]:
        q = p["queue"]
        if q not in deleted and q not in seen_queues and q not in ignored:
            ip = edited.get(q, {}).get("ip", p["ip"])
            printers.append({"ip": ip, "queue": q})
            seen_queues.add(q)

    # Remove ignored from excel-sourced printers too
    printers = [p for p in printers if p["queue"] not in ignored]

    return printers


def filter_printers(printers, user_data):
    if user_data.get("role") == "admin":
        return printers
    prefixes = user_data.get("prefixes", [])
    return [p for p in printers
            if any(p["queue"].upper().startswith(pf.upper()) for pf in prefixes)]


# ── SSH helper ────────────────────────────────────────────────────────────────

def ssh_run(command, timeout=20):
    """Return (stdout, stderr, success)."""
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(AIX_HOST, port=AIX_PORT,
                       username=AIX_USER, password=AIX_PASS,
                       timeout=timeout, banner_timeout=timeout)
        _, stdout, stderr = client.exec_command(command, timeout=timeout)
        out = stdout.read().decode("utf-8", errors="replace").strip()
        err = stderr.read().decode("utf-8", errors="replace").strip()
        client.close()
        return out, err, True
    except Exception as exc:
        return "", str(exc), False


# ── Auth guard ────────────────────────────────────────────────────────────────

def queue_allowed(queue):
    users     = load_users()
    user_data = users.get(session.get("username", ""), {})
    printers  = load_printers()
    allowed   = [p["queue"] for p in filter_printers(printers, user_data)]
    return queue in allowed


# ── Static assets from parent directory ──────────────────────────────────────

@app.route("/logo")
def serve_logo():
    p = _find_file("ekkanoo_logo.png")
    if p:
        return send_file(p, mimetype="image/png")
    return "", 404


@app.route("/bg")
def serve_bg():
    p = _find_file("Toyota Plaza.jpg", "Toyota_Plaza.jpg", "toyota_plaza.jpg")
    if p:
        return send_file(p, mimetype="image/jpeg")
    return "", 404


@app.route("/favicon.ico")
def favicon():
    p = _find_file("ekkanoo_logo.ico", "erp_ekk.ico")
    if p:
        return send_file(p, mimetype="image/x-icon")
    return "", 404


# ── Page routes ───────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return redirect(url_for("dashboard") if "username" in session else url_for("login"))


@app.route("/login", methods=["GET", "POST"])
def login():
    error = None
    if request.method == "POST":
        username = request.form.get("username", "").strip().lower()
        password = request.form.get("password", "").strip()
        users = load_users()
        if username in users and users[username]["password"] == password:
            session["username"] = username
            session["name"]     = users[username]["name"]
            session["role"]     = users[username]["role"]
            return redirect(url_for("dashboard"))
        error = "Invalid username or password."
    return render_template("login.html", error=error, version=APP_VERSION)


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.route("/dashboard")
def dashboard():
    if "username" not in session:
        return redirect(url_for("login"))
    users     = load_users()
    user_data = users.get(session["username"], {})
    printers  = filter_printers(load_printers(), user_data)
    return render_template("dashboard.html",
                           printers=printers,
                           user=session,
                           no_excel=not os.path.exists(EXCEL_FILE),
                           version=APP_VERSION)


# ── Queue status (bulk, one SSH call) ────────────────────────────────────────

@app.route("/api/status")
def api_status():
    if "username" not in session:
        return jsonify({"success": False, "statuses": {}}), 401

    # Only check queues this user can see
    users     = load_users()
    user_data = users.get(session["username"], {})
    printers  = filter_printers(load_printers(), user_data)
    if not printers:
        return jsonify({"success": True, "statuses": {}})

    # Parallel SSH: each queue runs lpstat + ping in a background subshell (&).
    # Format per queue: "QUEUENAME LPSTAT_STATUS ping_result"
    # Using & + wait means all 273 run simultaneously — total time ≈ slowest single call.
    entries = " ".join(
        "{}:{}".format(p["queue"], p["ip"] if p["ip"] else "none")
        for p in printers
    )
    cmd = (
        "for e in " + entries + "; do ("
        "q=${e%%:*}; ip=${e##*:}; "
        "s=$(lpstat -a$q 2>/dev/null | awk 'NR==3{print $3}'); "
        "if [ \"$ip\" = none ]; then pg=noip; "
        "else ping -c1 $ip >/dev/null 2>&1 && pg=up || pg=down; fi; "
        "printf '%s %s %s\\n' \"$q\" \"$s\" \"$pg\""
        ")& done; wait"
    )

    out, err, ok = ssh_run(cmd, timeout=90)
    if not ok:
        return jsonify({"success": False, "statuses": {}, "error": err})

    STATUS_MAP = {
        "READY":   "idle",
        "DOWN":    "disabled",
        "BUSY":    "printing",
        "RUNNING": "printing",
        "WAITING": "idle",
        "HELD":    "disabled",
    }

    statuses = {}
    for line in out.splitlines():
        parts = line.strip().split()
        if not parts:
            continue
        queue   = parts[0]
        lst_raw = parts[1].upper() if len(parts) > 1 else ""
        ping_st = parts[2]         if len(parts) > 2 else "up"

        mapped = STATUS_MAP.get(lst_raw, "unknown")
        if mapped == "disabled":
            statuses[queue] = "disabled"          # DOWN beats ping
        elif ping_st == "down":
            statuses[queue] = "offline"           # queue unknown but printer unreachable
        else:
            statuses[queue] = mapped

    return jsonify({"success": True, "statuses": statuses})


# ── Action API ────────────────────────────────────────────────────────────────

@app.route("/api/action", methods=["POST"])
def api_action():
    if "username" not in session:
        return jsonify({"success": False, "output": "Not authenticated"}), 401

    data   = request.get_json(force=True)
    action = data.get("action", "")
    queue  = data.get("queue", "").strip()
    ip     = data.get("ip", "").strip()

    if not queue_allowed(queue):
        return jsonify({"success": False, "output": "Access denied to this queue."}), 403

    # ── check queue ──
    if action == "check":
        out, err, ok = ssh_run(f"lpstat -a{queue} 2>&1")
        if not ok:
            return jsonify({"success": False, "output": err or "SSH connection failed."})
        if not out.strip():
            out = f"Queue '{queue}' not found on the AIX server."
        return jsonify({"success": True, "output": out})

    # ── cancel first job ──
    elif action == "cancel_first":
        # Don't suppress stderr — on some AIX versions output goes there
        out, err, ok = ssh_run(f"lpstat -o{queue}")
        if not ok:
            return jsonify({"success": False, "output": err or "SSH connection failed."})

        # Combine stdout + stderr so we don't miss anything
        raw = (out + "\n" + err).strip()
        if not raw:
            return jsonify({"success": True, "output": f"No jobs found in queue {queue}."})

        # Try regex: any AIX status word followed by job number
        job_id = None
        for line in raw.splitlines():
            m = re.search(r'(?:RUNNING|QUEUED|HELD|WAITING|PAUSED|ACTIVE)\s+(\d+)', line, re.IGNORECASE)
            if m:
                job_id = m.group(1)
                break

        # Fallback: awk extracts 4th column (Job number) from first data row
        if not job_id:
            awk_out, _, _ = ssh_run(
                "lpstat -o" + queue + " | awk 'NR>2 && NF>=4 {print $4; exit}'"
            )
            if awk_out.strip().isdigit():
                job_id = awk_out.strip()

        if not job_id:
            return jsonify({"success": True,
                            "output": f"Could not find job ID in queue {queue}.\n\nRaw lpstat output:\n{raw}"})

        out2, err2, ok2 = ssh_run(f"cancel {job_id} 2>&1")
        return jsonify({"success": ok2,
                        "output": f"Cancelled job {job_id} from {queue}.\n{out2 or err2 or 'Done.'}"})

    # ── cancel all jobs ──
    elif action == "cancel_all":
        out, err, ok = ssh_run(f"cancel {queue} 2>&1", timeout=30)
        return jsonify({"success": ok,
                        "output": out or err or f"Cancel command sent to queue {queue}."})

    # ── ping ──
    elif action == "ping":
        if not ip:
            return jsonify({"success": False, "output": "No IP address for this queue."})
        out, err, ok = ssh_run(f"ping -c 4 {ip}", timeout=25)
        return jsonify({"success": ok, "output": out or err})

    # ── enable ──
    elif action == "enable":
        out, err, ok = ssh_run(f"enable {queue}")
        return jsonify({"success": ok, "output": out or err or f"Queue {queue} enabled."})

    # ── disable ──
    elif action == "disable":
        out, err, ok = ssh_run(f"disable {queue}")
        return jsonify({"success": ok, "output": out or err or f"Queue {queue} disabled."})

    # ── print text sample ──
    elif action == "print_text":
        out, err, ok = ssh_run(f"lp -d {queue} /home/sample-print")
        return jsonify({"success": ok, "output": out or err or f"Text sample sent to {queue}."})

    # ── print PDF sample ──
    elif action == "print_pdf":
        out, err, ok = ssh_run(f"lp -d {queue} /home/sample-pdf.ps")
        return jsonify({"success": ok, "output": out or err or f"PDF sample sent to {queue}."})

    # ── qdaemon log ──
    elif action == "log":
        cmd = (f"tail -80 /var/spool/lpd/{queue}/log 2>/dev/null "
               f"|| tail -80 /var/adm/qdaemon 2>/dev/null "
               f"|| echo 'Log not found for queue {queue}'")
        out, err, ok = ssh_run(cmd, timeout=25)
        return jsonify({"success": ok, "output": out or err})

    # ── test SSH ──
    elif action == "test_ssh":
        out, err, ok = ssh_run("echo 'Connection OK'; uname -a; date", timeout=10)
        return jsonify({"success": ok, "output": out or err})

    else:
        return jsonify({"success": False, "output": f"Unknown action: {action}"})


def _parse_jobs(lpstat_output, queue):
    return re.findall(rf"{re.escape(queue)}-(\d+)", lpstat_output)


# ── Admin guard ───────────────────────────────────────────────────────────────

def admin_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if "username" not in session or session.get("role") != "admin":
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return decorated


# ── Admin printer management ──────────────────────────────────────────────────

@app.route("/admin/printers")
@admin_required
def admin_printers():
    override      = load_override()
    added_queues  = {p["queue"] for p in override["added"]}
    edited_queues = set(override["edited"].keys())
    ignored_set   = set(override["ignored"])
    deleted_set   = set(override["deleted"])

    # Build full list: active + ignored (so admin can see and restore)
    active    = load_printers()
    for p in active:
        q = p["queue"]
        if q in added_queues:
            p["source"] = "added"
        elif q in edited_queues:
            p["source"] = "edited"
        else:
            p["source"] = "excel"
        p["ignored"] = False

    # Ignored printers (rebuild them from Excel + added)
    ignored_printers = []
    if os.path.exists(EXCEL_FILE):
        df = pd.read_excel(EXCEL_FILE)
        df.columns = [c.strip() for c in df.columns]
        for _, row in df.iterrows():
            ip    = str(row.get("IP Address", "")).strip()
            queue = str(row.get("Printer Queue Name", "")).strip()
            if ip and queue and ip != "nan" and queue != "nan":
                if queue in ignored_set and queue not in deleted_set:
                    src = "edited" if queue in edited_queues else "excel"
                    ip  = override["edited"].get(queue, {}).get("ip", ip)
                    ignored_printers.append({"queue": queue, "ip": ip,
                                             "source": src, "ignored": True})
    for p in override["added"]:
        q = p["queue"]
        if q in ignored_set and q not in deleted_set:
            ip = override["edited"].get(q, {}).get("ip", p["ip"])
            ignored_printers.append({"queue": q, "ip": ip,
                                     "source": "added", "ignored": True})

    all_printers = active + ignored_printers
    return render_template("admin_printers.html",
                           printers=all_printers,
                           user=session,
                           version=APP_VERSION)


@app.route("/api/admin/printer/add", methods=["POST"])
@admin_required
def admin_add_printer():
    data  = request.get_json(force=True)
    queue = data.get("queue", "").strip().upper()
    ip    = data.get("ip", "").strip()
    if not queue or not ip:
        return jsonify({"success": False, "message": "Queue name and IP are required."})

    override = load_override()

    # If previously deleted, restore it
    if queue in override["deleted"]:
        override["deleted"].remove(queue)
        override["edited"][queue] = {"ip": ip}
        save_override(override)
        return jsonify({"success": True, "message": f"Printer '{queue}' restored."})

    # If ignored, un-ignore and update IP
    if queue in override["ignored"]:
        override["ignored"].remove(queue)
        override["edited"][queue] = {"ip": ip}
        save_override(override)
        return jsonify({"success": True, "message": f"Printer '{queue}' un-ignored and activated."})

    # Check if already active
    existing = {p["queue"] for p in load_printers()}
    if queue in existing:
        return jsonify({"success": False,
                        "message": f"Queue '{queue}' already exists. Use Edit IP to change address."})

    override["added"].append({"queue": queue, "ip": ip})
    save_override(override)
    return jsonify({"success": True, "message": f"Printer '{queue}' added successfully."})


@app.route("/api/admin/printer/edit", methods=["POST"])
@admin_required
def admin_edit_printer():
    data  = request.get_json(force=True)
    queue = data.get("queue", "").strip()
    ip    = data.get("ip", "").strip()
    if not queue or not ip:
        return jsonify({"success": False, "message": "Queue name and IP are required."})

    override = load_override()
    override["edited"][queue] = {"ip": ip}
    save_override(override)
    return jsonify({"success": True, "message": f"IP for '{queue}' updated to {ip}."})


@app.route("/api/admin/printer/delete", methods=["POST"])
@admin_required
def admin_delete_printer():
    data  = request.get_json(force=True)
    queue = data.get("queue", "").strip()
    if not queue:
        return jsonify({"success": False, "message": "Queue name required."})

    override = load_override()
    if queue not in override["deleted"]:
        override["deleted"].append(queue)
    override["added"]  = [p for p in override["added"]  if p["queue"] != queue]
    override["ignored"] = [q for q in override["ignored"] if q != queue]
    override["edited"].pop(queue, None)
    save_override(override)
    return jsonify({"success": True, "message": f"Printer '{queue}' deleted."})


@app.route("/api/admin/printer/ignore", methods=["POST"])
@admin_required
def admin_ignore_printer():
    data   = request.get_json(force=True)
    queue  = data.get("queue", "").strip()
    ignore = data.get("ignore", True)   # True = ignore, False = un-ignore
    if not queue:
        return jsonify({"success": False, "message": "Queue name required."})

    override = load_override()
    if ignore:
        if queue not in override["ignored"]:
            override["ignored"].append(queue)
        msg = f"Printer '{queue}' is now ignored (hidden from dashboard)."
    else:
        override["ignored"] = [q for q in override["ignored"] if q != queue]
        msg = f"Printer '{queue}' is now active."
    save_override(override)
    return jsonify({"success": True, "message": msg})


@app.route("/api/change-password", methods=["POST"])
def change_password():
    if "username" not in session:
        return jsonify({"success": False, "message": "Not authenticated."}), 401

    data         = request.get_json(force=True)
    current_pwd  = data.get("current_password", "")
    new_pwd      = data.get("new_password", "").strip()
    confirm_pwd  = data.get("confirm_password", "").strip()

    users    = load_users()
    username = session["username"]

    if users[username]["password"] != current_pwd:
        return jsonify({"success": False, "message": "Current password is incorrect."})
    if len(new_pwd) < 6:
        return jsonify({"success": False, "message": "New password must be at least 6 characters."})
    if new_pwd != confirm_pwd:
        return jsonify({"success": False, "message": "New passwords do not match."})

    users[username]["password"] = new_pwd
    save_users(users)
    return jsonify({"success": True, "message": "Password changed successfully."})


if __name__ == "__main__":
    print("=" * 55)
    print(f"  EKK Oracle Print Queue Portal  {APP_VERSION}")
    print(f"  Open browser: http://localhost:5000")
    print("=" * 55)
    app.run(host="0.0.0.0", port=5000, debug=False)
