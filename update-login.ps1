$content = @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>EKK Alert SMS Gateway - Sign In</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="icon" href="{{ url_for('static', filename='images/erp_ekk.ico') }}">
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{
      font-family:Segoe UI,Arial,sans-serif;
      min-height:100vh;
      display:flex;
      flex-direction:column;
      background:#1a6ab8;
      position:relative;
      overflow:hidden;
    }
    .bg-fallback{
      position:fixed;
      inset:0;
      background:linear-gradient(135deg,#1b5ea8 0%,#2e80d0 40%,#1a72c4 70%,#0f52a0 100%);
      z-index:-1;
    }
    .bg{
      position:fixed;
      inset:0;
      background:url("{{ url_for('static', filename='images/ekk_building.jpg') }}") center/cover no-repeat;
      opacity:0.50;
      z-index:0;
    }
    .overlay{
      position:fixed;
      inset:0;
      background:rgba(255,255,255,0.08);
      z-index:1;
    }
    .ai-watermark{
      position:fixed;
      inset:0;
      opacity:0.13;
      z-index:2;
      pointer-events:none;
    }
    .content{
      position:relative;
      z-index:3;
      flex:1;
      display:flex;
      align-items:center;
      justify-content:center;
      padding:40px 16px;
    }
    .card{
      background:#ffffff;
      border-radius:14px;
      padding:24px 28px 22px;
      width:100%;
      max-width:360px;
      box-shadow:0 12px 40px rgba(0,0,0,0.28);
      text-align:center;
    }
    .card-logo{height:48px;margin-bottom:12px;}
    .card h2{font-size:16px;font-weight:800;color:#1a2a3a;margin-bottom:4px;}
    .card-sub{font-size:12px;color:#8B1A1A;font-weight:600;margin-bottom:18px;}
    .fields-row{display:flex;gap:10px;margin-bottom:12px;}
    .form-group{flex:1;text-align:left;}
    label{display:block;font-size:11px;font-weight:700;color:#334155;margin-bottom:4px;}
    input{
      width:100%;padding:8px 10px;border:1.5px solid #d1d9e0;
      border-radius:8px;font:inherit;font-size:13px;color:#1a2a3a;
      background:#f8fafc;transition:border-color .2s;
    }
    input:focus{outline:none;border-color:#8B1A1A;background:#fff;}
    .btn-signin{
      width:100%;padding:10px;background:#1a3a6e;color:#fff;
      border:none;border-radius:8px;font:inherit;font-size:14px;
      font-weight:700;cursor:pointer;letter-spacing:.02em;transition:background .2s;
    }
    .btn-signin:hover{background:#122b55}
    .flash-success{
      background:#e8f7ee;color:#116b39;border:1px solid #cdecd8;
      border-radius:8px;padding:8px 12px;margin-bottom:12px;font-size:12px;font-weight:600;text-align:left;
    }
    .flash-error{
      background:#fdeceb;color:#a12622;border:1px solid #f5cbc9;
      border-radius:8px;padding:8px 12px;margin-bottom:12px;font-size:12px;font-weight:600;text-align:left;
    }
    footer{
      position:relative;z-index:3;text-align:center;padding:12px 16px;
      font-size:12px;color:#fff;background:rgba(0,0,0,0.40);letter-spacing:.01em;
    }
  </style>
</head>
<body>

  <div class="bg-fallback"></div>
  <div class="bg"></div>
  <div class="overlay"></div>

  <!-- AI Neural Network Watermark -->
  <div class="ai-watermark">
    <svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%">
      <defs>
        <pattern id="neural-net" x="0" y="0" width="210" height="190" patternUnits="userSpaceOnUse">
          <!-- Connections -->
          <g stroke="white" stroke-width="0.8" fill="none">
            <!-- Input to Hidden-1 -->
            <line x1="18" y1="32" x2="75" y2="16"/>
            <line x1="18" y1="32" x2="75" y2="52"/>
            <line x1="18" y1="32" x2="75" y2="88"/>
            <line x1="18" y1="68" x2="75" y2="16"/>
            <line x1="18" y1="68" x2="75" y2="52"/>
            <line x1="18" y1="68" x2="75" y2="88"/>
            <line x1="18" y1="68" x2="75" y2="124"/>
            <line x1="18" y1="104" x2="75" y2="52"/>
            <line x1="18" y1="104" x2="75" y2="88"/>
            <line x1="18" y1="104" x2="75" y2="124"/>
            <line x1="18" y1="104" x2="75" y2="160"/>
            <line x1="18" y1="140" x2="75" y2="88"/>
            <line x1="18" y1="140" x2="75" y2="124"/>
            <line x1="18" y1="140" x2="75" y2="160"/>
            <!-- Hidden-1 to Hidden-2 -->
            <line x1="75" y1="16" x2="135" y2="32"/>
            <line x1="75" y1="16" x2="135" y2="68"/>
            <line x1="75" y1="52" x2="135" y2="32"/>
            <line x1="75" y1="52" x2="135" y2="68"/>
            <line x1="75" y1="52" x2="135" y2="104"/>
            <line x1="75" y1="88" x2="135" y2="32"/>
            <line x1="75" y1="88" x2="135" y2="68"/>
            <line x1="75" y1="88" x2="135" y2="104"/>
            <line x1="75" y1="88" x2="135" y2="140"/>
            <line x1="75" y1="124" x2="135" y2="68"/>
            <line x1="75" y1="124" x2="135" y2="104"/>
            <line x1="75" y1="124" x2="135" y2="140"/>
            <line x1="75" y1="160" x2="135" y2="104"/>
            <line x1="75" y1="160" x2="135" y2="140"/>
            <!-- Hidden-2 to Output -->
            <line x1="135" y1="32" x2="190" y2="58"/>
            <line x1="135" y1="32" x2="190" y2="114"/>
            <line x1="135" y1="68" x2="190" y2="58"/>
            <line x1="135" y1="68" x2="190" y2="114"/>
            <line x1="135" y1="104" x2="190" y2="58"/>
            <line x1="135" y1="104" x2="190" y2="114"/>
            <line x1="135" y1="140" x2="190" y2="58"/>
            <line x1="135" y1="140" x2="190" y2="114"/>
          </g>
          <!-- Nodes -->
          <g fill="white">
            <circle cx="18" cy="32" r="4.5"/>
            <circle cx="18" cy="68" r="4.5"/>
            <circle cx="18" cy="104" r="4.5"/>
            <circle cx="18" cy="140" r="4.5"/>
            <circle cx="75" cy="16" r="4"/>
            <circle cx="75" cy="52" r="4"/>
            <circle cx="75" cy="88" r="4"/>
            <circle cx="75" cy="124" r="4"/>
            <circle cx="75" cy="160" r="4"/>
            <circle cx="135" cy="32" r="4"/>
            <circle cx="135" cy="68" r="4"/>
            <circle cx="135" cy="104" r="4"/>
            <circle cx="135" cy="140" r="4"/>
            <circle cx="190" cy="58" r="5.5"/>
            <circle cx="190" cy="114" r="5.5"/>
          </g>
        </pattern>
      </defs>
      <rect width="100%" height="100%" fill="url(#neural-net)"/>
    </svg>
  </div>

  <div class="content">
    <div class="card">

      <img class="card-logo"
           src="{{ url_for('static', filename='images/ekkanoo_logo.png') }}"
           alt="Ebrahim K. Kanoo">

      <h2>EKK ERP-ICT Alert SMS Gateway</h2>
      <div class="card-sub">Alert SMS for Servers, Network and BMS</div>

      {% if error %}
        <div class="flash-error">{{ error }}</div>
      {% endif %}
      {% with messages = get_flashed_messages(with_categories=True) %}
        {% for category, msg in messages %}
          <div class="flash-{{ 'success' if category == 'success' else 'error' }}">{{ msg }}</div>
        {% endfor %}
      {% endwith %}

      <form method="post">
        <div class="fields-row">
          <div class="form-group">
            <label for="username">Username</label>
            <input id="username" name="username" type="text"
                   autocomplete="username" autofocus required>
          </div>
          <div class="form-group">
            <label for="password">Password</label>
            <input id="password" name="password" type="password"
                   autocomplete="current-password" required>
          </div>
        </div>
        <button class="btn-signin" type="submit">Sign In</button>
      </form>

    </div>
  </div>

  <footer>
    &copy; EKK Alert SMS Gateway v1.0.2024 &nbsp;|&nbsp; Ebrahim K. Kanoo &nbsp;|&nbsp; IT Department
  </footer>

</body>
</html>
'@

$target = "C:\sms\EKK_Alert_SMS_Gateway\templates\login.html"
Copy-Item $target "$target.bak" -Force
Set-Content -Path $target -Value $content -Encoding UTF8
Write-Host "Done! login.html updated successfully." -ForegroundColor Green
