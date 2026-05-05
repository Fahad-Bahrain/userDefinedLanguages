from flask import Flask, render_template, request, redirect, url_for, session, jsonify, send_file
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
USERS_FILE = os.path.join(BASE_DIR, "users.json")


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


def load_printers():
    if not os.path.exists(EXCEL_FILE):
        return []
    df = pd.read_excel(EXCEL_FILE)
    df.columns = [c.strip() for c in df.columns]
    printers = []
    for _, row in df.iterrows():
        ip    = str(row.get("IP Address", "")).strip()
        queue = str(row.get("Printer Queue Name", "")).strip()
        if ip and queue and ip != "nan" and queue != "nan":
            printers.append({"ip": ip, "queue": queue})
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
    return render_template("login.html", error=error)


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

    out, err, ok = ssh_run("lpstat -p 2>&1", timeout=30)
    if not ok:
        return jsonify({"success": False, "statuses": {}, "error": err})

    statuses = {}
    for line in out.splitlines():
        m = re.match(r"printer\s+(\S+)\s+(.*)", line.strip(), re.IGNORECASE)
        if m:
            qname = m.group(1)
            rest  = m.group(2).lower()
            if "now printing" in rest:
                statuses[qname] = "printing"
            elif "is idle" in rest:
                statuses[qname] = "idle"
            elif "disabled" in rest:
                statuses[qname] = "disabled"
            else:
                statuses[qname] = "unknown"

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
        out, err, ok = ssh_run(f"lpstat -p {queue}; echo; lpstat -o {queue}")
        if not ok:
            return jsonify({"success": False, "output": err})
        jobs = _parse_jobs(out, queue)
        if not out.strip():
            out = f"Queue '{queue}' — no status returned (queue may not exist on server)."
        return jsonify({"success": True, "output": out, "jobs": jobs})

    # ── cancel first job ──
    elif action == "cancel_first":
        out, err, ok = ssh_run(f"lpstat -o {queue}")
        if not ok:
            return jsonify({"success": False, "output": err})
        jobs = _parse_jobs(out, queue)
        if not jobs:
            return jsonify({"success": True, "output": f"No jobs found in queue {queue}."})
        first = jobs[0]
        out2, err2, ok2 = ssh_run(f"cancel {queue}-{first}")
        return jsonify({"success": ok2,
                        "output": f"Cancelled first job: {queue}-{first}\n{out2 or err2}"})

    # ── cancel all jobs ──
    elif action == "cancel_all":
        out, err, ok = ssh_run(f"lpstat -o {queue}")
        if not ok:
            return jsonify({"success": False, "output": err})
        jobs = _parse_jobs(out, queue)
        if not jobs:
            return jsonify({"success": True, "output": f"No jobs in queue {queue}."})
        cancel_cmd = "; ".join(f"cancel {queue}-{j}" for j in jobs)
        out2, err2, ok2 = ssh_run(cancel_cmd)
        return jsonify({"success": ok2,
                        "output": f"Cancelled {len(jobs)} job(s): {', '.join(jobs)}\n{out2 or err2}"})

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


if __name__ == "__main__":
    print("=" * 55)
    print(f"  EKK Oracle Print Queue Portal  {APP_VERSION}")
    print(f"  Open browser: http://localhost:5000")
    print("=" * 55)
    app.run(host="0.0.0.0", port=5000, debug=False)
