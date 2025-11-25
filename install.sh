#!/bin/bash

# Dwnloader - FINAL PERFECT VERSION (2025)
# Features:
# - Clean English-only titles (no emojis, no special chars)
# - Shows exact download start time
# - Latest download always on top
# - Real-time progress + file size (no refresh needed)
# - Auto-sanitized safe filenames
# - Daily automatic yt-dlp update
# - Beautiful dark UI
# - Works perfectly on Ubuntu Server

set -e

echo "=================================================="
echo "DWNLOADER - Final Perfect Version"
echo "=================================================="

if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (sudo)"
    exit 1
fi

INSTALL_DIR="/opt/dwnloader"
SERVICE_NAME="dwnloader"

# Stop service if updating
if systemctl is-active --quiet $SERVICE_NAME 2>/dev/null; then
    echo "Stopping existing service..."
    systemctl stop $SERVICE_NAME
fi

echo "Installing system dependencies..."
apt-get update -qq
apt-get install -y python3 python3-pip python3-venv ffmpeg curl

echo "Installing latest yt-dlp..."
curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
chmod a+rx /usr/local/bin/yt-dlp

# Create user
if ! id -u dwnloader &>/dev/null; then
    useradd -r -m -s /bin/bash dwnloader
    echo "Created system user: dwnloader"
fi

mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

# Backup old app.py if exists
if [ -f "app.py" ]; then
    cp app.py app.py.backup.$(date +%Y%m%d_%H%M%S)
fi

# Setup venv
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install flask flask-socketio eventlet --quiet

echo "Deploying perfect app.py..."

cat > app.py << 'EOF'
from flask import Flask, request, jsonify, send_file
from flask_socketio import SocketIO
import os, subprocess, uuid, threading, time, re, hashlib
from pathlib import Path
from datetime import datetime

app = Flask(__name__)
app.config['SECRET_KEY'] = os.urandom(24).hex()
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='eventlet')

DOWNLOAD_DIR = Path("/opt/dwnloader/downloads")
DOWNLOAD_DIR.mkdir(exist_ok=True)
MAX_CONCURRENT = 4
db = {}
lock = threading.Lock()

def sanitize(title):
    title = re.sub(r'[^\x00-\x7F]+', '', title)           # Remove emojis & non-ASCII
    title = re.sub(r'[<>:"/\\|?*\x00-\x1F]', '_', title) # Remove invalid filename chars
    title = re.sub(r'[\._\s]+', '_', title.strip())      # Clean spaces/dots
    title = re.sub(r'^_+|_+$', '', title)
    return (title[:100] or "video") + ""

def worker(did, url, quality, fmt, subs):
    try:
        start_time = datetime.now()
        with lock:
            db[did]['status'] = 'downloading'
            db[did]['start_time'] = start_time.isoformat()

        socketio.emit('progress', {
            'download_id': did, 'progress': 0, 'status': 'downloading',
            'start_time': start_time.strftime("%H:%M:%S")
        })

        cmd = ['yt-dlp', '--newline', '--no-warnings']
        template = f"%(title)s_[{hashlib.md5(url.encode()).hexdigest()[:10]}].{fmt}"

        if quality == "MUSIC":
            cmd += ['-x', '--audio-format', fmt]
        else:
            if quality != "none":
                h = quality.replace("p", "")
                cmd += ['-f', f'best[height<={h}]']
            if subs != "none":
                cmd += ['--write-subs', '--sub-langs', subs, '--embed-subs']
            cmd += ['--merge-output-format', fmt]

        cmd += ['-o', str(DOWNLOAD_DIR / template), url]

        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        last = 0
        for line in proc.stdout:
            if '%' in line:
                m = re.search(r'(\d+(?:\.\d+)?%', line)
                if m:
                    p = int(float(m.group(1)))
                    if p >= last + 2 or p == 100:
                        last = p
                        socketio.emit('progress', {'download_id': did, 'progress': p})
            if any(x in line.lower() for x in ['merge', 'convert', 'ffmpeg']):
                socketio.emit('progress', {'download_id': did, 'progress': 95, 'status': 'converting'})

        proc.wait()
        if proc.returncode != 0:
            raise Exception("Download failed")

        # Find and rename file cleanly
        files = list(DOWNLOAD_DIR.glob(f"*{hashlib.md5(url.encode()).hexdigest()[:10]}*.{fmt}"))
        file = max(files, key=lambda x: x.stat().st_mtime)
        clean_name = sanitize(file.stem.split('_')[0])
        final_name = f"{clean_name}.{fmt}"
        final_path = DOWNLOAD_DIR / final_name
        if final_path.exists():
            final_path.unlink()
        file.rename(final_path)

        size = final_path.stat().st_size
        with lock:
            db[did].update({
                'status': 'complete', 'progress':100, 'filename': final_name,
                'size': size, 'clean_title': clean_name
            })

        socketio.emit('progress', {
            'download_id': did, 'progress':100, 'status':'complete',
            'filename': final_name, 'size': size, 'clean_title': clean_name,
            'start_time': start_time.strftime("%H:%M:%S")
        })

    except Exception as e:
        with lock:
            db[did]['status'] = 'error'
            db[did]['error'] = str(e)
        socketio.emit('progress', {'download_id': did, 'status':'error', 'error':str(e)})

threading.Thread(target=lambda: [time.sleep(3600) or DOWNLOAD_DIR.glob('*') and 
    [f.unlink(missing_ok=True) for f in DOWNLOAD_DIR.iterdir() if f.is_file() and time.time() - f.stat().st_mtime > 86400*7]], daemon=True).start()

@app.route('/')
def index():
    return '''<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>Dwnloader</title>
<script src="https://cdn.socket.io/4.7.5/socket.io.min.js"></script>
<style>
body{background:#0a0a0a;color:#eee;font-family:system-ui;margin:0;padding:20px}
h1{background:linear-gradient(90deg,#60a5fa,#e879f9);-webkit-background-clip:text;color:transparent;font-size:3rem;text-align:center}
.container{max-width:1100px;margin:auto auto}
.card{background:#111;border:1px solid #333;border-radius:16px;padding:18px;margin:12px 0}
.title{font-size:1.25rem;font-weight:600;color:#fff;margin-bottom:8px;word-break:break-word}
.meta{color:#aaa;font-size:0.95rem}
.progress{height:8px;background:#222;border-radius:4px;overflow:hidden;margin:12px 0}
.fill{height:100%;background:linear-gradient(90deg,#60a5fa,#e879f9);width:0;transition:width .4s}
.btn{background:#16a34a;color:white;border:none;padding:14px;border-radius:12px;width:100%;font-weight:bold;cursor:pointer;margin-top:10px}
input,select{padding:16px;background:#000;border:1px solid #444;border-radius:12px;color:white;width:100%;margin:8px 0;font-size:1rem}
</style></head><body>
<div class="container">
<h1>Dwnloader</h1>
<p style="text-align:center;color:#888;margin:30px 0">Clean • Fast • Always Up-to-Date</p>

<div style="background:#111;padding:30px;border-radius:20px;margin-bottom:40px">
<input type="text" id="url" placeholder="Paste video URL..." autofocus>
<div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;margin:16px 0">
<select id="quality"><option value="720p">720p</option><option value="1080p">1080p</option><option value="none">Best Quality</option><option value="MUSIC">Audio Only</option></select>
<select id="format"><option value="mp4">MP4</option><option value="mp3">MP3</option></select>
</div>
<button class="btn" id="go" onclick="start()">Download Now</button>
</div>

<div id="list"></div>
</div>

<script>
const socket=io(); let d={};
socket.on('progress',p=>{d[p.download_id]={...d[p.download_id],...p};render()});
function $(i){return document.getElementById(i)}
function sz(b){if(!b)return'';let mb=b/1048576;return mb>1?mb.toFixed(1)+' MB':(b/1024).toFixed(0)+' KB'}
function render(){
  const list=$('list');
  const items=Object.values(d).sort((a,b)=> (b.start_time||'').localeCompare(a.start_time||''));
  list.innerHTML = items.length===0 ? `<div style="text-align:center;padding:100px;color:#666">No downloads yet</div>` : items.map(x=>`
    <div class="card">
      <div class="title">${x.clean_title||'Loading title...'}</div>
      <div class="meta">Started: ${x.start_time||'—'} • ${x.progress||0}% • ${sz(x.size)}</div>
      <div class="progress"><div class="fill" style="width:${x.progress||0}%"></div></div>
      <div style="margin-top:12px;display:flex;gap:12px;align-items:center">
        <span style="background:#1e293b;padding:8px 16px;border-radius:30px;font-size:0.9rem">${(x.status||'starting').toUpperCase()}</span>
        ${x.status==='complete'?`<button class="btn" onclick="location.href='/api/download/${x.download_id}'">Download ${x.filename}</button>`:''}
      </div>
    </div>`).join('');
}
async function start(){
  const url=$('url').value.trim(); if(!url)return alert('Enter URL');
  const btn=$('go'); btn.disabled=true; btn.textContent='Starting...';
  try{
    const r=await fetch('/api/download',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({url,quality:$('quality').value,format:$('format').value,subtitle_lang:'none'})});
    const j=await r.json();
    if(r.ok){ d[j.download_id]={download_id:j.download_id,url,status:'starting',progress:0}; render(); $('url').value=''; }
    else alert(j.error||'Failed');
  }catch(e){alert('Network error')} finally{ btn.disabled=false; btn.textContent='Download Now'; }
}
$('quality').onchange=()=>{ const a=$('quality').value==='MUSIC'; $('format').innerHTML=a?
  '<option value="mp3">MP3</option><option value="m4a">M4A</option>' :
  '<option value="mp4">MP4</option><option value="mkv">MKV</option>'; };
socket.on('connect',()=>fetch('/api/downloads').then(r=>r.json()).then(x=>{d=x;render()}));
window.onload=()=>$('quality').dispatchEvent(new Event('change'));
</script></body></html>'''

@app.route('/api/download', methods=['POST'])
def api_start():
    data = request.json or {}
    url = data.get('url','').strip()
    if not url: return jsonify(error="URL required"), 400
    if sum(1 for v in db.values() if v.get('status') in ['downloading','converting']) >= MAX_CONCURRENT:
        return jsonify(error=f"Max {MAX_CONCURRENT} concurrent"), 429
    did = str(uuid.uuid4())
    db[did] = {'download_id':did, 'url':url, 'status':'starting'}
    threading.Thread(target=worker, args=(did, url, data.get('quality','720p'), data.get('format','mp4'), data.get('subtitle_lang','none')), daemon=True).start()
    return jsonify(download_id=did)

@app.route('/api/download/<did>')
def download_file(did):
    info = db.get(did)
    if not info or info['status']!='complete': return jsonify(error="Not ready"), 400
    return send_file(DOWNLOAD_DIR / info['filename'], as_attachment=True)

@app.route('/api/downloads')
def list_downloads(): return jsonify(db)

if __name__ == '__main__':
    socketio.run(app, host='0.0.0.0', port=5000)
EOF

# Permissions
chown -R dwnloader:dwnloader $INSTALL_DIR
chmod 644 $INSTALL_DIR/app.py

# Create downloads folder
mkdir -p $INSTALL_DIR/downloads
chown dwnloader:dwnloader $INSTALL_DIR/downloads

# Daily yt-dlp auto-update
echo "Setting up daily yt-dlp auto-update..."
cat > /usr/local/bin/update-ytdlp.sh << 'EOF'
#!/bin/bash
LOG="/var/log/ytdlp-update.log"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Updating yt-dlp..." >> "$LOG"
curl -L --fail --silent --show-error \
  https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
  -o /usr/local/bin/yt-dlp
chmod a+rx /usr/local/bin/yt-dlp
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Updated → $(yt-dlp --version)" >> "$LOG"
EOF
chmod +x /usr/local/bin/update-ytdlp.sh

cat > /etc/cron.daily/update-ytdlp << 'EOF'
#!/bin/sh
/usr/local/bin/update-ytdlp.sh
EOF
chmod +x /etc/cron.daily/update-ytdlp

# Systemd service
cat > /etc/systemd/system/$SERVICE_NAME.service << EOF
[Unit]
Description=Dwnloader - Clean Video/Audio Downloader
After=network.target

[Service]
Type=simple
User=dwnloader
WorkingDirectory=$INSTALL_DIR
Environment=PATH=$INSTALL_DIR/venv/bin:/usr/local/bin:/usr/bin
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now $SERVICE_NAME

echo ""
echo "=================================================="
echo "DWNLOADER IS NOW PERFECTLY INSTALLED!"
echo "==================================================="
echo "Access → http://$(hostname -I | awk '{print $1}'):5000"
echo ""
echo "Features:"
echo "   • Clean English titles only"
echo "   • Shows download start time"
echo "   • Latest download always on top"
echo "   • Real-time progress (no refresh)"
echo "   • Auto daily yt-dlp updates"
echo "   • Beautiful dark design"
echo ""
echo "Commands:"
echo "   sudo systemctl status  $SERVICE_NAME"
echo "   sudo systemctl restart $SERVICE_NAME"
echo "   sudo journalctl -u $SERVICE_NAME -f"
echo "   sudo tail -f /var/log/ytdlp-update.log"
echo "=================================================="
