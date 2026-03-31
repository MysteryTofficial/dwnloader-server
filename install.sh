#!/bin/bash
# dwnloader installer v4.0 — self-contained (curl-pipe friendly)
# Usage: curl -sSL https://raw.githubusercontent.com/.../install.sh | sudo bash

# ── When piped through curl, stdin is the pipe, not the terminal.
# ── Save ourselves to a temp file and re-exec with /dev/tty as stdin.
if [ ! -t 0 ]; then
    _tmp=$(mktemp /tmp/dwnloader-install.XXXXXX.sh)
    cat > "$_tmp"
    chmod +x "$_tmp"
    exec bash "$_tmp" < /dev/tty
fi

set -e

# ── colours ───────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[1;37m'; N='\033[0m'
BOLD='\033[1m'; DIM='\033[2m'

ok()   { echo -e "  ${G}✓${N}  $1"; }
info() { echo -e "  ${B}→${N}  $1"; }
warn() { echo -e "  ${Y}!${N}  $1"; }
fail() { echo -e "\n  ${R}✗  $1${N}\n"; exit 1; }
step() { echo -e "\n${BOLD}${W}── $1${N}"; }

# ── header ────────────────────────────────────────────────────────────────────
clear 2>/dev/null || true
echo -e "${DIM}────────────────────────────────────────────${N}"
echo -e "  ${W}${BOLD}dwnloader${N}  —  installer"
echo -e "${DIM}────────────────────────────────────────────${N}\n"

# ── root check ────────────────────────────────────────────────────────────────
[ "$EUID" -ne 0 ] && fail "Run with sudo:  curl ... | sudo bash"

# ── detect mode ───────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/dwnloader"
SERVICE="dwnloader"
MODE="install"
[ -d "$INSTALL_DIR" ] && MODE="update"

if [ "$MODE" = "update" ]; then
    echo -e "  Found existing installation at ${C}${INSTALL_DIR}${N}"
    echo -e "  This will ${Y}update${N} dwnloader in-place, keeping your settings.\n"
    read -rp "  Continue? [Y/n] " _confirm < /dev/tty
    [[ "$_confirm" =~ ^[Nn] ]] && { echo -e "\n  Cancelled.\n"; exit 0; }
else
    echo -e "  Installing to ${C}${INSTALL_DIR}${N}\n"
fi

# ── configuration (fresh install only) ───────────────────────────────────────
if [ "$MODE" = "install" ]; then
    step "Configuration"
    echo -e "  ${DIM}Press Enter to accept the default shown in brackets.${N}\n"

    read -rp "  Port               [5000]: " _p < /dev/tty;  PORT="${_p:-5000}"
    read -rp "  Admin username    [admin]: " _u < /dev/tty;  ADMIN_USER="${_u:-admin}"

    while true; do
        echo -ne "  Admin password  [auto-gen]: "; read -rs _pw < /dev/tty; echo
        if [ -z "$_pw" ]; then
            ADMIN_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 18)
            AUTO_PASS=true
            break
        elif [ ${#_pw} -lt 8 ]; then
            echo -e "  ${Y}Password must be at least 8 characters. Try again.${N}"
        else
            echo -ne "  Confirm password:           "; read -rs _pw2 < /dev/tty; echo
            if [ "$_pw" = "$_pw2" ]; then
                ADMIN_PASS="$_pw"
                AUTO_PASS=false
                break
            else
                echo -e "  ${Y}Passwords do not match. Try again.${N}"
            fi
        fi
    done

    read -rp "  Concurrent DLs        [3]: " _c < /dev/tty;  MAX_CONCURRENT="${_c:-3}"
    read -rp "  Keep files (hours)   [24]: " _h < /dev/tty;  CLEANUP_HOURS="${_h:-24}"
    echo
else
    # Preserve existing settings on update
    source /etc/dwnloader/config 2>/dev/null || true
    PORT="${PORT:-5000}"
    ADMIN_USER="${ADMIN_USER:-admin}"
    MAX_CONCURRENT="${MAX_CONCURRENT:-3}"
    CLEANUP_HOURS="${CLEANUP_HOURS:-24}"
    AUTO_PASS=false
fi

# ── system deps ───────────────────────────────────────────────────────────────
step "System dependencies"
apt-get update -qq 2>/dev/null
apt-get install -y -qq python3 python3-pip python3-venv ffmpeg curl 2>/dev/null
ok "python3, ffmpeg, curl"

step "yt-dlp"
curl -sSL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
    -o /usr/local/bin/yt-dlp
chmod a+rx /usr/local/bin/yt-dlp
_ver=$(/usr/local/bin/yt-dlp --version 2>/dev/null || echo "unknown")
ok "yt-dlp ${_ver}"

# ── app directory ─────────────────────────────────────────────────────────────
step "Application"

if [ "$MODE" = "install" ] && ! id dwnloader &>/dev/null; then
    useradd -r -m -s /bin/bash dwnloader
    ok "System user: dwnloader"
fi

mkdir -p "${INSTALL_DIR}/downloads"
cd "${INSTALL_DIR}"

if [ "$MODE" = "update" ] && [ -f app.py ]; then
    cp app.py "app.py.bak.$(date +%Y%m%d_%H%M%S)"
    info "Backed up old app.py"
fi

# ── write app.py ──────────────────────────────────────────────────────────────
info "Writing app.py..."
cat > "${INSTALL_DIR}/app.py" << 'PYEOF'
"""
dwnloader — minimal self-hosted video & audio downloader
Session-based login with bcrypt password hashing + CSRF protection
"""
from flask import (Flask, request, jsonify, send_file,
                   session, redirect, url_for)
from flask_socketio import SocketIO
import os, subprocess, uuid, threading, time, re, unicodedata, hashlib, secrets
from pathlib import Path
from datetime import datetime
import bcrypt
from jinja2 import Template

app = Flask(__name__)
app.config['SECRET_KEY']             = os.getenv('SECRET_KEY', secrets.token_hex(32))
app.config['SESSION_COOKIE_HTTPONLY'] = True
app.config['SESSION_COOKIE_SAMESITE'] = 'Lax'
app.config['SESSION_COOKIE_SECURE']   = os.getenv('HTTPS', '0') == '1'

socketio = SocketIO(app, cors_allowed_origins="*", async_mode='eventlet',
                    ping_timeout=60, ping_interval=25)

# ── credentials ───────────────────────────────────────────────────────────────
ADMIN_USER    = os.getenv('ADMIN_USER', 'admin')
PASSWORD_HASH = os.getenv('PASSWORD_HASH', '').encode()

# ── brute-force protection ────────────────────────────────────────────────────
_login_attempts = {}
_attempts_lock  = threading.Lock()
MAX_ATTEMPTS    = 5
LOCKOUT_SECS    = 15 * 60

def check_rate_limit(ip):
    now = time.time()
    with _attempts_lock:
        rec = _login_attempts.get(ip, {'count': 0, 'locked_until': 0})
        if rec['locked_until'] > now:
            return False, int(rec['locked_until'] - now)
        return True, 0

def record_failure(ip):
    with _attempts_lock:
        rec = _login_attempts.get(ip, {'count': 0, 'locked_until': 0})
        rec['count'] += 1
        if rec['count'] >= MAX_ATTEMPTS:
            rec['locked_until'] = time.time() + LOCKOUT_SECS
            rec['count'] = 0
        _login_attempts[ip] = rec

def clear_failures(ip):
    with _attempts_lock:
        _login_attempts.pop(ip, None)

# ── auth helpers ──────────────────────────────────────────────────────────────
def logged_in():
    return session.get('authenticated') is True

def login_required(f):
    from functools import wraps
    @wraps(f)
    def decorated(*args, **kwargs):
        if not logged_in():
            if request.path.startswith('/api/'):
                return jsonify({'error': 'Not authenticated'}), 401
            return redirect(url_for('login_page'))
        return f(*args, **kwargs)
    return decorated

# ── app config ────────────────────────────────────────────────────────────────
DOWNLOAD_DIR   = Path(os.getenv('DOWNLOAD_DIR', 'downloads'))
YTDLP_EXEC     = os.getenv('YTDLP_PATH', 'yt-dlp')
MAX_CONCURRENT = int(os.getenv('MAX_CONCURRENT', '3'))
CLEANUP_HOURS  = int(os.getenv('CLEANUP_HOURS', '24'))
PORT           = int(os.getenv('PORT', '5000'))
DOWNLOAD_DIR.mkdir(exist_ok=True)

downloads_db   = {}
downloads_lock = threading.Lock()

# ── utilities ─────────────────────────────────────────────────────────────────
def check_ytdlp():
    try:
        subprocess.run([YTDLP_EXEC, "--version"], capture_output=True, timeout=5, check=True)
        return True
    except Exception:
        return False

def url_hash(url):
    return hashlib.md5(url.encode()).hexdigest()[:12]

def sanitize(name):
    base = name.rsplit('.', 1)[0] if '.' in name else name
    norm = unicodedata.normalize('NFKD', base)
    clean = ''.join(c for c in norm if c.isascii() and (c.isalnum() or c in ' -_'))
    return ' '.join(clean.split()).strip(' -_') or 'download'

# ── download worker ───────────────────────────────────────────────────────────
def download_worker(dl_id, url, quality, subtitle_lang, fmt):
    def emit(progress, status, **kw):
        with downloads_lock:
            downloads_db[dl_id].update({'progress': progress, 'status': status, **kw})
        socketio.emit('progress', {'download_id': dl_id, 'progress': progress,
                                   'status': status, **kw})
    try:
        emit(0, 'downloading')
        h   = url_hash(url)
        cmd = [YTDLP_EXEC, '--no-playlist', '--no-warnings', '--progress', '--newline']
        if quality == 'audio':
            cmd += ['-x', '--audio-format', fmt, '--audio-quality', '0',
                    '--embed-thumbnail', '--add-metadata']
        else:
            if quality != 'best':
                h_val = quality.rstrip('p')
                cmd += ['-f', f'bestvideo[height<={h_val}][ext=mp4]+bestaudio[ext=m4a]/best[height<={h_val}]']
            else:
                cmd += ['-f', 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best']
            if subtitle_lang != 'none':
                cmd += ['--write-subs', '--sub-langs', subtitle_lang, '--embed-subs']
            cmd += ['--merge-output-format', fmt]
        cmd += ['-o', str(DOWNLOAD_DIR / f'{h}_%(title).80s.%(ext)s'), url]

        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, bufsize=1)
        last = 0
        for line in proc.stdout:
            if '[download]' in line and '%' in line:
                m = re.search(r'(\d+(?:\.\d+)?)%', line)
                if m:
                    p = int(float(m.group(1)))
                    if p - last >= 5 or p == 100:
                        last = p; emit(p, 'downloading')
            elif any(x in line for x in ['[ffmpeg]', 'Merging', 'Converting']):
                emit(95, 'converting')
        proc.wait()

        if proc.returncode != 0:
            raise Exception(f"yt-dlp exited with code {proc.returncode}")

        files = list(DOWNLOAD_DIR.glob(f'{h}_*.{fmt}'))
        if not files:
            files = [f for f in DOWNLOAD_DIR.glob(f'{h}_*') if f.is_file()]
        if not files:
            raise Exception("Downloaded file not found")

        src = max(files, key=lambda x: x.stat().st_mtime)
        ext = src.suffix.lstrip('.')
        dst = DOWNLOAD_DIR / f'{sanitize(src.stem[len(h)+1:])}.{ext}'
        if dst.exists(): dst = src
        elif src != dst: src.rename(dst)

        emit(100, 'complete', filename=dst.name, size=dst.stat().st_size,
             timestamp=datetime.now().isoformat())
    except Exception as e:
        emit(0, 'error', error=str(e))

# ── cleanup worker ────────────────────────────────────────────────────────────
def cleanup_worker():
    while True:
        try:
            cutoff = time.time() - CLEANUP_HOURS * 3600
            for f in DOWNLOAD_DIR.glob('*'):
                if f.is_file() and f.stat().st_mtime < cutoff:
                    f.unlink()
            with downloads_lock:
                stale = [k for k, v in downloads_db.items()
                         if v.get('status') == 'complete'
                         and datetime.fromisoformat(v['timestamp']).timestamp() < cutoff]
                for k in stale: del downloads_db[k]
        except Exception as e:
            print(f'[cleanup] {e}')
        time.sleep(1800)

threading.Thread(target=cleanup_worker, daemon=True).start()

# ─────────────────────────────────────────────────────────────────────────────
# HTML templates
# ─────────────────────────────────────────────────────────────────────────────
LOGIN_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>dwnloader — sign in</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=DM+Mono:wght@400;500&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet">
<style>
:root {
  --bg:#f5f4f0;--surface:#efefeb;--border:#d8d7d2;
  --text:#1a1a18;--muted:#888884;--accent:#1a1a18;
  --red:#b84040;--r:6px;
  --mono:'DM Mono',monospace;--sans:'DM Sans',sans-serif;
}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{font-family:var(--sans);background:var(--bg);color:var(--text);
  min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px}
.box{width:100%;max-width:340px}
h1{font-family:var(--mono);font-size:1.05rem;font-weight:500;margin-bottom:4px}
.sub{font-size:.8rem;color:var(--muted);margin-bottom:28px}
.field{margin-bottom:12px}
label{display:block;font-size:.75rem;color:var(--muted);margin-bottom:5px;font-family:var(--mono)}
input{width:100%;font-family:var(--mono);font-size:.85rem;background:var(--surface);
  border:1px solid var(--border);border-radius:var(--r);padding:10px 12px;
  color:var(--text);outline:none;transition:border-color .15s}
input:focus{border-color:var(--accent)}
.msg{font-size:.78rem;border-radius:var(--r);padding:8px 11px;margin-bottom:14px;border:1px solid}
.msg.error{color:var(--red);background:#fdf2f2;border-color:var(--red)}
.msg.lockout{color:#92400e;background:#fef3c7;border-color:#d97706}
button{width:100%;font-family:var(--sans);font-weight:600;font-size:.85rem;
  background:var(--accent);color:var(--bg);border:none;border-radius:var(--r);
  padding:11px;cursor:pointer;margin-top:4px;transition:opacity .15s}
button:hover{opacity:.85}
button:disabled{opacity:.4;cursor:not-allowed}
</style>
</head>
<body>
<div class="box">
  <h1>dwnloader</h1>
  <p class="sub">Sign in to continue.</p>
  {% if locked %}
  <div class="msg lockout">Too many failed attempts. Try again in {{ locked_mins }} minute{{ 's' if locked_mins != 1 else '' }}.</div>
  {% elif error %}
  <div class="msg error">{{ error }}</div>
  {% endif %}
  <form method="POST" action="/login">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="field">
      <label>Username</label>
      <input type="text" name="username" autocomplete="username" autofocus
             value="{{ username|default('') }}" {% if locked %}disabled{% endif %}>
    </div>
    <div class="field">
      <label>Password</label>
      <input type="password" name="password" autocomplete="current-password"
             {% if locked %}disabled{% endif %}>
    </div>
    <button type="submit" {% if locked %}disabled{% endif %}>Sign in</button>
  </form>
</div>
</body>
</html>"""

APP_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>dwnloader</title>
<script src="https://cdn.socket.io/4.5.4/socket.io.min.js"></script>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=DM+Mono:wght@400;500&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet">
<style>
:root{--bg:#f5f4f0;--surface:#efefeb;--border:#d8d7d2;--text:#1a1a18;--muted:#888884;
  --accent:#1a1a18;--green:#2d7a4f;--red:#b84040;--blue:#2d5a9e;--r:6px;
  --mono:'DM Mono',monospace;--sans:'DM Sans',sans-serif}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{font-family:var(--sans);background:var(--bg);color:var(--text);min-height:100vh;padding:32px 16px 80px}
.wrap{max-width:680px;margin:0 auto}
header{display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:36px}
.header-left h1{font-family:var(--mono);font-size:1.05rem;font-weight:500;letter-spacing:-.01em}
.header-left p{font-size:.8rem;color:var(--muted);margin-top:3px}
.btn-logout{font-family:var(--mono);font-size:.72rem;color:var(--muted);background:none;
  border:1px solid var(--border);border-radius:var(--r);padding:5px 10px;cursor:pointer;
  transition:color .12s,border-color .12s;white-space:nowrap}
.btn-logout:hover{color:var(--red);border-color:var(--red)}
.card{background:var(--surface);border:1px solid var(--border);border-radius:var(--r);padding:18px;margin-bottom:16px}
.url-row{display:flex;gap:8px;margin-bottom:12px}
.url-row input{flex:1;font-family:var(--mono);font-size:.83rem;background:var(--bg);
  border:1px solid var(--border);border-radius:var(--r);padding:9px 11px;color:var(--text);
  outline:none;transition:border-color .15s}
.url-row input:focus{border-color:var(--accent)}
.url-row input::placeholder{color:var(--muted)}
.opts{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px}
select{font-family:var(--sans);font-size:.8rem;background:var(--bg);border:1px solid var(--border);
  border-radius:var(--r);padding:7px 9px;color:var(--text);outline:none;cursor:pointer;flex:1;min-width:90px}
select:focus{border-color:var(--accent)}
select:disabled{opacity:.4;cursor:default}
button{font-family:var(--sans);font-weight:500;font-size:.83rem;border:1px solid var(--border);
  border-radius:var(--r);padding:9px 14px;cursor:pointer;background:var(--bg);color:var(--text);
  transition:background .12s,opacity .12s;white-space:nowrap}
button:hover:not(:disabled){background:var(--border)}
.btn-primary{background:var(--accent);color:var(--bg);border-color:var(--accent);width:100%;padding:10px}
.btn-primary:hover:not(:disabled){opacity:.82;background:var(--accent)}
.btn-primary:disabled{opacity:.38;cursor:not-allowed}
.btn-save{background:transparent;border-color:var(--green);color:var(--green);font-size:.76rem;padding:5px 11px}
.btn-save:hover{background:var(--green)!important;color:#fff}
.toast{font-size:.8rem;padding:8px 11px;border-radius:var(--r);margin-bottom:11px;display:none;border:1px solid}
.toast.err{color:var(--red);border-color:var(--red);background:#fdf2f2}
.toast.info{color:var(--blue);border-color:var(--blue);background:#f2f5fd}
.toast.show{display:block}
.section-label{font-family:var(--mono);font-size:.7rem;color:var(--muted);text-transform:uppercase;
  letter-spacing:.09em;margin-bottom:10px}
.dl-item{border:1px solid var(--border);border-radius:var(--r);padding:13px;margin-bottom:8px;background:var(--bg)}
.dl-top{display:flex;justify-content:space-between;align-items:flex-start;gap:10px;margin-bottom:8px}
.dl-name{font-family:var(--mono);font-size:.78rem;word-break:break-all;flex:1;line-height:1.45}
.dl-name.muted{color:var(--muted);font-size:.73rem}
.badge{font-size:.65rem;font-weight:600;font-family:var(--mono);letter-spacing:.04em;
  padding:2px 6px;border-radius:3px;white-space:nowrap;flex-shrink:0}
.s-downloading{background:#dbeafe;color:#1e40af}
.s-converting{background:#ede9fe;color:#5b21b6}
.s-complete{background:#d1fae5;color:#065f46}
.s-error{background:#fee2e2;color:#991b1b}
.s-starting{background:#fef9c3;color:#78350f}
.bar-wrap{height:2px;background:var(--border);border-radius:1px;margin-bottom:8px;overflow:hidden}
.bar-fill{height:100%;background:var(--accent);border-radius:1px;transition:width .3s}
.bar-fill.done{background:var(--green)}
.bar-fill.error{background:var(--red)}
.dl-meta{font-size:.71rem;color:var(--muted);display:flex;justify-content:space-between;flex-wrap:wrap;gap:6px}
.dl-foot{margin-top:9px;text-align:right}
.dl-err{font-size:.7rem;color:var(--red);font-family:var(--mono);margin-top:6px;line-height:1.4}
.empty{text-align:center;padding:48px 20px;font-size:.82rem;color:var(--muted);font-family:var(--mono)}
body.drag-over::after{content:'Drop URL here';position:fixed;inset:12px;border:2px dashed var(--accent);
  border-radius:8px;display:flex;align-items:center;justify-content:center;font-family:var(--mono);
  font-size:1rem;color:var(--accent);background:rgba(245,244,240,.88);pointer-events:none;z-index:999}
@media(max-width:480px){.opts,.url-row{flex-direction:column}}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="header-left">
      <h1>dwnloader</h1>
      <p>Paste a URL, pick a format, hit download.</p>
    </div>
    <button class="btn-logout" onclick="logout()">sign out</button>
  </header>
  <div class="card">
    <div id="toast" class="toast"></div>
    <div class="url-row">
      <input id="url" type="text" placeholder="https://..." autocomplete="off" spellcheck="false">
      <button onclick="paste()">Paste</button>
    </div>
    <div class="opts">
      <select id="type" onchange="syncFormats()">
        <option value="audio">Audio</option>
        <option value="720p">720p</option>
        <option value="1080p">1080p</option>
        <option value="1440p">1440p</option>
        <option value="2160p">4K</option>
        <option value="best">Best video</option>
      </select>
      <select id="fmt"></select>
      <select id="subs">
        <option value="none">No subtitles</option>
        <option value="en">English</option>
        <option value="es">Spanish</option>
        <option value="fr">French</option>
        <option value="de">German</option>
        <option value="ja">Japanese</option>
        <option value="zh">Chinese</option>
      </select>
    </div>
    <button class="btn-primary" id="dlBtn" onclick="go()">Download</button>
  </div>
  <p class="section-label">Downloads</p>
  <div id="list"></div>
</div>
<script>
const socket=io();const db={};
const AUDIO=['mp3','m4a','flac','wav','opus'];const VIDEO=['mp4','mkv','webm'];
function syncFormats(){
  const audio=document.getElementById('type').value==='audio';
  const sel=document.getElementById('fmt');
  sel.innerHTML=(audio?AUDIO:VIDEO).map(f=>
    `<option value="${f}"${(audio&&f==='mp3')||(!audio&&f==='mp4')?' selected':''}>${f}</option>`
  ).join('');
  document.getElementById('subs').disabled=audio;
}
const fmt_bytes=b=>{if(!b)return'';const k=1024,s=['B','KB','MB','GB'],i=Math.floor(Math.log(b)/Math.log(k));return(b/k**i).toFixed(1)+' '+s[i]};
const fmt_time=t=>t?new Date(t).toLocaleString(undefined,{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}):'';
const badge_cls=s=>({downloading:'s-downloading',converting:'s-converting',complete:'s-complete',error:'s-error',starting:'s-starting'})[s]||'s-starting';
const bar_cls=s=>s==='complete'?'done':s==='error'?'error':'';
function render(){
  const list=document.getElementById('list');
  const items=Object.values(db).sort((a,b)=>new Date(b.timestamp||0)-new Date(a.timestamp||0));
  if(!items.length){list.innerHTML='<div class="empty">nothing yet</div>';return}
  list.innerHTML=items.map(d=>{
    const label=d.filename||d.url||'';const muted=!d.filename;const prog=d.progress||0;
    return`<div class="dl-item">
  <div class="dl-top"><div class="dl-name${muted?' muted':''}" title="${label}">${label}</div>
  <span class="badge ${badge_cls(d.status)}">${d.status||'—'}</span></div>
  <div class="bar-wrap"><div class="bar-fill ${bar_cls(d.status)}" style="width:${prog}%"></div></div>
  <div class="dl-meta"><span>${d.status==='downloading'?prog+'%':d.status==='error'?'failed':fmt_bytes(d.size)}</span><span>${fmt_time(d.timestamp)}</span></div>
  ${d.status==='error'&&d.error?`<div class="dl-err">${d.error}</div>`:''}
  ${d.status==='complete'?`<div class="dl-foot"><button class="btn-save" onclick="location.href='/api/download/${d.id}'">↓ Save file</button></div>`:''}
</div>`}).join('');
}
socket.on('progress',d=>{db[d.download_id]={...db[d.download_id],...d};render()});
socket.on('connect',()=>{fetch('/api/downloads').then(r=>r.json()).then(d=>{Object.assign(db,d);render()})});
setInterval(()=>{fetch('/api/downloads').then(r=>r.json()).then(d=>{Object.assign(db,d);render()}).catch(()=>{})},5000);
function toast(msg,type='info'){const el=document.getElementById('toast');el.className=`toast show ${type}`;el.textContent=msg;clearTimeout(el._t);el._t=setTimeout(()=>el.classList.remove('show'),4000)}
async function paste(){try{document.getElementById('url').value=(await navigator.clipboard.readText()).trim();document.getElementById('url').focus()}catch{toast('Paste manually (Ctrl+V)','err')}}
async function go(){
  const url=document.getElementById('url').value.trim();
  if(!url){toast('Enter a URL first','err');return}
  const btn=document.getElementById('dlBtn');btn.disabled=true;btn.textContent='Starting…';
  try{
    const res=await fetch('/api/download',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({url,quality:document.getElementById('type').value,
        format:document.getElementById('fmt').value,subtitle_lang:document.getElementById('subs').value})});
    const data=await res.json();
    if(res.ok){db[data.download_id]={id:data.download_id,url,status:'starting',progress:0,timestamp:new Date().toISOString()};render();document.getElementById('url').value='';toast('Download queued','info')}
    else if(res.status===401){location.href='/login'}
    else{toast(data.error||'Something went wrong','err')}
  }catch{toast('Network error','err')}
  finally{btn.disabled=false;btn.textContent='Download'}
}
async function logout(){await fetch('/logout',{method:'POST'});location.href='/login'}
document.getElementById('url').addEventListener('keydown',e=>{if(e.key==='Enter')go()});
document.addEventListener('dragover',e=>{e.preventDefault();document.body.classList.add('drag-over')});
document.addEventListener('dragleave',e=>{if(!e.relatedTarget)document.body.classList.remove('drag-over')});
document.addEventListener('drop',e=>{e.preventDefault();document.body.classList.remove('drag-over');const url=e.dataTransfer.getData('text/uri-list')||e.dataTransfer.getData('text/plain')||'';if(url)document.getElementById('url').value=url.trim()});
syncFormats();render();
</script>
</body>
</html>"""

# ── auth routes ───────────────────────────────────────────────────────────────
@app.route('/login', methods=['GET'])
def login_page():
    if logged_in():
        return redirect(url_for('index'))
    ip = request.remote_addr
    ok_rate, remaining = check_rate_limit(ip)
    csrf = secrets.token_hex(16)
    session['csrf'] = csrf
    locked_mins = (remaining // 60) + 1 if remaining > 0 else 0
    return Template(LOGIN_HTML).render(
        csrf_token=csrf, error=None,
        locked=not ok_rate, locked_mins=locked_mins
    )

@app.route('/login', methods=['POST'])
def login_post():
    ip = request.remote_addr
    ok_rate, remaining = check_rate_limit(ip)
    locked_mins = (remaining // 60) + 1 if remaining > 0 else 0

    if not ok_rate:
        csrf = secrets.token_hex(16); session['csrf'] = csrf
        return Template(LOGIN_HTML).render(
            csrf_token=csrf, error=None, locked=True, locked_mins=locked_mins
        ), 429

    # CSRF validation
    form_csrf    = request.form.get('csrf_token', '')
    session_csrf = session.get('csrf', '')
    if not secrets.compare_digest(form_csrf, session_csrf):
        return Template(LOGIN_HTML).render(
            csrf_token=secrets.token_hex(16),
            error='Invalid request — please try again.',
            locked=False, locked_mins=0
        ), 400

    username = request.form.get('username', '').strip()
    password = request.form.get('password', '').encode()

    # Always run bcrypt to prevent timing attacks revealing valid usernames
    user_ok = secrets.compare_digest(username, ADMIN_USER)
    try:
        pass_ok = bcrypt.checkpw(password, PASSWORD_HASH) if PASSWORD_HASH else False
    except Exception:
        pass_ok = False

    if user_ok and pass_ok:
        clear_failures(ip)
        session.clear()
        session['authenticated'] = True
        session.permanent = True
        return redirect(url_for('index'))

    record_failure(ip)
    ok_rate2, remaining2 = check_rate_limit(ip)
    locked_mins2 = (remaining2 // 60) + 1 if remaining2 > 0 else 0
    csrf = secrets.token_hex(16); session['csrf'] = csrf
    if not ok_rate2:
        return Template(LOGIN_HTML).render(
            csrf_token=csrf, error=None, locked=True, locked_mins=locked_mins2
        ), 429
    return Template(LOGIN_HTML).render(
        csrf_token=csrf, error='Incorrect username or password.',
        locked=False, locked_mins=0, username=username
    ), 401

@app.route('/logout', methods=['POST'])
def logout():
    session.clear()
    return ('', 204)

# ── app routes ────────────────────────────────────────────────────────────────
@app.route('/')
@login_required
def index():
    return APP_HTML

@app.route('/api/check')
@login_required
def api_check():
    return jsonify({
        'ytdlp': check_ytdlp(),
        'total': len(downloads_db),
        'active': sum(1 for d in downloads_db.values()
                      if d['status'] in ('downloading', 'converting'))
    })

@app.route('/api/download', methods=['POST'])
@login_required
def api_start():
    data = request.json or {}
    url  = data.get('url', '').strip()
    if not url:           return jsonify({'error': 'URL required'}), 400
    if not check_ytdlp(): return jsonify({'error': 'yt-dlp not found'}), 500
    active = sum(1 for d in downloads_db.values()
                 if d['status'] in ('downloading', 'converting'))
    if active >= MAX_CONCURRENT:
        return jsonify({'error': f'Max {MAX_CONCURRENT} concurrent downloads — wait for one to finish'}), 429
    dl_id = str(uuid.uuid4())
    with downloads_lock:
        downloads_db[dl_id] = {
            'id': dl_id, 'url': url,
            'quality': data.get('quality', 'audio'),
            'format':  data.get('format', 'mp3'),
            'status': 'starting', 'progress': 0,
            'timestamp': datetime.now().isoformat()
        }
    threading.Thread(
        target=download_worker,
        args=(dl_id, url, data.get('quality', 'audio'),
              data.get('subtitle_lang', 'none'), data.get('format', 'mp3')),
        daemon=True
    ).start()
    return jsonify({'download_id': dl_id})

@app.route('/api/download/<dl_id>')
@login_required
def api_get_file(dl_id):
    with downloads_lock:
        info = downloads_db.get(dl_id)
    if not info or info['status'] != 'complete':
        return jsonify({'error': 'Not ready'}), 404
    fp = DOWNLOAD_DIR / info['filename']
    if not fp.exists():
        return jsonify({'error': 'File missing'}), 404
    return send_file(fp, as_attachment=True, download_name=info['filename'])

@app.route('/api/downloads')
@login_required
def api_list_downloads():
    with downloads_lock:
        return jsonify(dict(downloads_db))

if __name__ == '__main__':
    socketio.run(app, host='0.0.0.0', port=PORT, debug=False)
PYEOF
ok "app.py written"

# ── python env ────────────────────────────────────────────────────────────────
step "Python environment"
[ ! -d "${INSTALL_DIR}/venv" ] && python3 -m venv "${INSTALL_DIR}/venv"
"${INSTALL_DIR}/venv/bin/pip" install -q --upgrade pip
"${INSTALL_DIR}/venv/bin/pip" install -q --upgrade \
    flask flask-socketio python-socketio python-engineio eventlet bcrypt
ok "Dependencies installed"

# ── hash the password with bcrypt ─────────────────────────────────────────────
if [ "$MODE" = "install" ]; then
    info "Hashing password with bcrypt..."
    PASSWORD_HASH=$("${INSTALL_DIR}/venv/bin/python3" -c \
        "import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(rounds=12)).decode())" \
        "$ADMIN_PASS")
    ok "Password hashed (bcrypt, 12 rounds)"
else
    # On update: keep existing hash from config
    source /etc/dwnloader/config 2>/dev/null || true
    [ -z "${PASSWORD_HASH:-}" ] && warn "No existing password hash found in config — you may need to reinstall"
fi

# Generate or preserve stable secret key
if [ "$MODE" = "install" ] || ! grep -q "^SECRET_KEY=" /etc/dwnloader/config 2>/dev/null; then
    SECRET_KEY=$(head /dev/urandom | tr -dc A-Fa-f0-9 | head -c 64)
else
    source /etc/dwnloader/config 2>/dev/null || true
fi

# ── config file ───────────────────────────────────────────────────────────────
mkdir -p /etc/dwnloader
chmod 700 /etc/dwnloader
cat > /etc/dwnloader/config << CONF
ADMIN_USER=${ADMIN_USER}
PASSWORD_HASH=${PASSWORD_HASH}
SECRET_KEY=${SECRET_KEY}
PORT=${PORT}
MAX_CONCURRENT=${MAX_CONCURRENT}
CLEANUP_HOURS=${CLEANUP_HOURS}
CONF
chmod 600 /etc/dwnloader/config
ok "Config saved → /etc/dwnloader/config"

# ── systemd service ───────────────────────────────────────────────────────────
step "Service"
cat > /etc/systemd/system/${SERVICE}.service << UNIT
[Unit]
Description=dwnloader — video/audio downloader
After=network.target

[Service]
Type=simple
User=dwnloader
Group=dwnloader
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=/etc/dwnloader/config
Environment="PATH=${INSTALL_DIR}/venv/bin:/usr/local/bin:/usr/bin"
Environment="DOWNLOAD_DIR=${INSTALL_DIR}/downloads"
ExecStart=${INSTALL_DIR}/venv/bin/python app.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

chown -R dwnloader:dwnloader "${INSTALL_DIR}"
chown root:root /etc/dwnloader/config
systemctl daemon-reload
[ "$MODE" = "install" ] && systemctl enable "$SERVICE" -q
systemctl restart "$SERVICE"
ok "Service started"

# ── daily yt-dlp auto-update ──────────────────────────────────────────────────
cat > /etc/cron.daily/dwnloader-ytdlp-update << 'CRON'
#!/bin/bash
curl -sSL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
    -o /usr/local/bin/yt-dlp && chmod a+rx /usr/local/bin/yt-dlp
CRON
chmod +x /etc/cron.daily/dwnloader-ytdlp-update
ok "yt-dlp auto-update scheduled (daily)"

# ── done ──────────────────────────────────────────────────────────────────────
sleep 2
SERVER_IP=$(hostname -I | awk '{print $1}')

echo -e "\n${DIM}────────────────────────────────────────────${N}"
echo -e "  ${G}${BOLD}All done.${N}\n"
echo -e "  ${W}URL       ${N}http://${SERVER_IP}:${PORT}"
echo -e "  ${W}Username  ${N}${ADMIN_USER}"
if [ "$MODE" = "install" ]; then
    echo -e "  ${W}Password  ${BOLD}${ADMIN_PASS}${N}"
    [ "$AUTO_PASS" = "true" ] && echo -e "  ${DIM}↑ auto-generated — copy it now${N}"
    echo -e "  ${DIM}  (stored as bcrypt hash — plaintext is never saved to disk)${N}"
fi
echo -e "\n  ${DIM}To change the password:${N}"
echo -e "  ${DIM}  sudo /opt/dwnloader/venv/bin/python3 -c \\${N}"
echo -e "  ${DIM}    \"import bcrypt; h=bcrypt.hashpw(input('New password: ').encode(),bcrypt.gensalt(12)).decode(); print(h)\"${N}"
echo -e "  ${DIM}  Paste the output as PASSWORD_HASH in /etc/dwnloader/config${N}"
echo -e "  ${DIM}  sudo systemctl restart dwnloader${N}"
echo -e "\n  ${DIM}Live logs:  journalctl -u dwnloader -f${N}"
echo -e "${DIM}────────────────────────────────────────────${N}\n"
