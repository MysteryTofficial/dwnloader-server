#!/bin/bash

# Dwnloader - Ubuntu Server Installation/Update Script (FIXED + CLEAN FILENAMES)
# Run with: sudo bash install.sh

set -e

echo "=================================================="
echo "DWNLOADER - Installation/Update Script (v2.1 - Clean Filenames Fixed)"
echo "=================================================="

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

INSTALL_DIR="/opt/dwnloader"
SERVICE_NAME="dwnloader"
UPDATING=false

# Check if already installed
if [ -d "$INSTALL_DIR" ]; then
    echo "Existing installation detected at $INSTALL_DIR"
    echo "Running UPDATE mode..."
    UPDATING=true
    
    if systemctl is-active --quiet $SERVICE_NAME; then
        echo "Stopping $SERVICE_NAME service..."
        systemctl stop $SERVICE_NAME
    fi
else
    echo "Running FRESH INSTALLATION mode..."
fi

echo "Installing/Updating system dependencies..."
apt-get update
apt-get install -y python3 python3-pip python3-venv ffmpeg curl

echo "Installing/Updating yt-dlp..."
curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
chmod a+rx /usr/local/bin/yt-dlp

if [ "$UPDATING" = false ]; then
    echo "Creating dwnloader user..."
    if ! id -u dwnloader &>/dev/null; then
        useradd -r -m -s /bin/bash dwnloader
    fi
fi

echo "Setting up application directory..."
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

if [ "$UPDATING" = true ]; then
    echo "Backing up old app.py..."
    [ -f "app.py" ] && cp app.py app.py.backup.$(date +%Y%m%d_%H%M%S)
fi

echo "Setting up Python virtual environment..."
[ ! -d "venv" ] && python3 -m venv venv
source venv/bin/activate

echo "Installing/Updating Python dependencies..."
pip install --upgrade pip
pip install --upgrade flask flask-socketio python-socketio python-engineio eventlet

echo "Creating/Updating app.py (with CLEAN filenames!)"
cat > app.py << 'EOF'
"""
Dwnloader - Blazingly Fast Multi-User Video/Audio Downloader
NOW WITH PERFECTLY CLEAN FILENAMES
"""

from flask import Flask, request, jsonify, send_file
from flask_socketio import SocketIO
import os
import subprocess
import uuid
import threading
import time
import re
import unicodedata
from pathlib import Path
from datetime import datetime
import hashlib

app = Flask(__name__)
app.config['SECRET_KEY'] = os.getenv('SECRET_KEY', str(uuid.uuid4()))
app.config['MAX_CONTENT_LENGTH'] = 50 * 1024 * 1024
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='eventlet', ping_timeout=60, ping_interval=25)

DOWNLOAD_DIR = Path(os.getenv('DOWNLOAD_DIR', 'downloads'))
YTDLP_EXEC = os.getenv('YTDLP_PATH', 'yt-dlp')
MAX_CONCURRENT = int(os.getenv('MAX_CONCURRENT', '3'))
CLEANUP_HOURS = int(os.getenv('CLEANUP_HOURS', '24'))

DOWNLOAD_DIR.mkdir(exist_ok=True)

downloads_db = {}
downloads_lock = threading.Lock()

def check_ytdlp():
    try:
        subprocess.run([YTDLP_EXEC, "--version"], capture_output=True, timeout=5, check=True)
        return True
    except:
        return False

def get_url_hash(url):
    return hashlib.md5(url.encode()).hexdigest()[:12]

def sanitize_filename(filename):
    name_without_ext = filename.rsplit('.', 1)[0] if '.' in filename else filename
    normalized = unicodedata.normalize('NFKD', name_without_ext)
    sanitized = ''.join(c for c in normalized if c.isascii() and (c.isalnum() or c in ' -_'))
    sanitized = ' '.join(sanitized.split())
    sanitized = sanitized.strip(' -_')
    return sanitized if sanitized else 'download'

def download_worker(download_id, url, quality, subtitle_lang, output_format):
    try:
        with downloads_lock:
            downloads_db[download_id]['status'] = 'downloading'
        
        socketio.emit('progress', {'download_id': download_id, 'progress': 0, 'status': 'downloading'})
        
        cmd = [YTDLP_EXEC, '--no-playlist', '--no-warnings', '--progress', '--newline']
        
        if quality == "MUSIC":
            cmd.extend(['-x', '--audio-format', output_format, '--audio-quality', '0', '--embed-thumbnail', '--add-metadata'])
            output_template = str(DOWNLOAD_DIR / f"{get_url_hash(url)}_%(title).60s.{output_format}")
        else:
            if quality != "none":
                height = quality.replace("p", "")
                cmd.extend([ '-f', f'bestvideo[height<={height}][ext=mp4]+bestaudio[ext=m4a]/best[height<={height}]' ])
            else:
                cmd.extend(['-f', 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best'])
            
            if subtitle_lang != "none":
                cmd.extend(['--write-subs', '--sub-langs', subtitle_lang, '--embed-subs'])
            
            cmd.extend(['--merge-output-format', output_format])
            output_template = str(DOWNLOAD_DIR / f"{get_url_hash(url)}_%(title).60s.{output_format}")
        
        cmd.extend(['-o', output_template, url])
        
        process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        last_progress = 0
        
        for line in process.stdout:
            if '[download]' in line and '%' in line:
                match = re.search(r'(\d+(?:\.\d+)?)%', line)
                if match:
                    progress = int(float(match.group(1)))
                    if progress - last_progress >= 5 or progress == 100:
                        last_progress = progress
                        with downloads_lock:
                            downloads_db[download_id]['progress'] = progress
                        socketio.emit('progress', {'download_id': download_id, 'progress': progress, 'status': 'downloading'})
            
            elif any(x in line for x in ['[ffmpeg]', 'Merging', 'Converting']):
                with downloads_lock:
                    downloads_db[download_id]['status'] = 'converting'
                socketio.emit('progress', {'download_id': download_id, 'progress': 95, 'status': 'converting'})
        
        process.wait()
        
        # SUCCESS + CLEAN FILENAME LOGIC (THIS WAS MISSING BEFORE!)
        if process.returncode == 0:
            files = list(DOWNLOAD_DIR.glob(f"{get_url_hash(url)}_*.{output_format}"))
            if not files:
                raise Exception("Downloaded file not found")

            final_file = max(files, key=lambda x: x.stat().st_mtime)
            dirty_title = final_file.stem[len(get_url_hash(url)) + 1 :]
            clean_title = sanitize_filename(dirty_title)
            if not clean_title:
                clean_title = "download"

            new_filename = f"{clean_title}.{output_format}"
            new_path = DOWNLOAD_DIR / new_filename

            if new_path.exists():
                new_filename = final_file.name
                new_path = final_file
            else:
                if new_path != final_file:
                    final_file.rename(new_path)

            file_size = new_path.stat().st_size

            with downloads_lock:
                downloads_db[download_id].update({
                    'status': 'complete',
                    'filename': new_filename,
                    'progress': 100,
                    'size': file_size,
                    'timestamp': datetime.now().isoformat()
                })

            socketio.emit('progress', {
                'download_id': download_id,
                'progress': 100,
                'status': 'complete',
                'filename': new_filename,
                'size': file_size
            })
        else:
            raise Exception(f"yt-dlp exited with code {process.returncode}")
    
    except Exception as e:
        with downloads_lock:
            downloads_db[download_id]['status'] = 'error'
            downloads_db[download_id]['error'] = str(e)
        
        socketio.emit('progress', {
            'download_id': download_id,
            'progress': 0,
            'status': 'error',
            'error': str(e)
        })

# Cleanup thread (unchanged)
def cleanup_worker():
    while True:
        try:
            cutoff = time.time() - (CLEANUP_HOURS * 3600)
            deleted = 0
            for file_path in DOWNLOAD_DIR.glob('*'):
                if file_path.is_file() and file_path.stat().st_mtime < cutoff:
                    file_path.unlink()
                    deleted += 1
            if deleted > 0:
                print(f"[CLEANUP] Removed {deleted} old files")
            
            with downloads_lock:
                to_remove = [dl_id for dl_id, info in downloads_db.items()
                            if info.get('status') == 'complete' and 
                            datetime.fromisoformat(info['timestamp']).timestamp() < cutoff]
                for dl_id in to_remove:
                    del downloads_db[dl_id]
        except Exception as e:
            print(f"[CLEANUP ERROR] {e}")
        time.sleep(1800)

threading.Thread(target=cleanup_worker, daemon=True).start()

# Routes (unchanged - already perfect)
@app.route('/')
def index():
    return '''<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Dwnloader</title><script src="https://cdn.socket.io/4.5.4/socket.io.min.js"></script><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0a0a0a;color:#e0e0e0;min-height:100vh;padding:20px}.container{max-width:1200px;margin:0 auto}.header{text-align:center;margin-bottom:40px;padding:20px;background:linear-gradient(135deg,#1a1a1a,#2a2a2a);border-radius:12px;border:1px solid #333}h1{font-size:2rem;margin-bottom:8px;background:linear-gradient(135deg,#60a5fa,#a78bfa);-webkit-background-clip:text;-webkit-text-fill-color:transparent}p{color:#888;font-size:.9rem}.input-section{background:#1a1a1a;padding:24px;border-radius:12px;margin-bottom:24px;border:1px solid #333}.input-group{display:flex;gap:12px;margin-bottom:16px}input,select{background:#0a0a0a;border:1px solid #333;color:#e0e0e0;padding:12px;border-radius:8px;font-size:.95rem;transition:all .2s;flex:1}input:focus,select:focus{outline:none;border-color:#60a5fa;box-shadow:0 0 0 2px rgba(96,165,250,.1)}.options{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:16px}button{padding:12px 24px;border:none;border-radius:8px;font-weight:600;cursor:pointer;transition:all .2s}.btn-primary{background:linear-gradient(135deg,#60a5fa,#a78bfa);color:white;width:100%}.btn-primary:hover{transform:translateY(-2px);box-shadow:0 4px 12px rgba(96,165,250,.4)}.btn-primary:disabled{opacity:.5;cursor:not-allowed;transform:none}.downloads{background:#1a1a1a;border-radius:12px;padding:24px;border:1px solid #333}h2{margin-bottom:20px;font-size:1.3rem}.download-card{background:#0a0a0a;border:1px solid #333;border-radius:8px;padding:16px;margin-bottom:12px;transition:all .2s}.download-card:hover{border-color:#444;transform:translateX(4px)}.download-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:12px;gap:12px}.download-url{flex:1;color:#888;font-size:.85rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.status{padding:4px 12px;border-radius:12px;font-size:.75rem;font-weight:600}.status-downloading{background:#1e3a8a;color:#60a5fa}.status-converting{background:#581c87;color:#a78bfa}.status-complete{background:#065f46;color:#34d399}.status-error{background:#7f1d1d;color:#f87171}.progress-bar{height:4px;background:#2a2a2a;border-radius:2px;overflow:hidden;margin-bottom:12px}.progress-fill{height:100%;background:linear-gradient(90deg,#60a5fa,#a78bfa);transition:width .3s}.download-info{display:flex;justify-content:space-between;font-size:.8rem;color:#666;margin-bottom:8px;gap:16px}.btn-download{background:#065f46;color:#34d399;width:100%;margin-top:8px}.btn-download:hover{background:#047857}.empty{text-align:center;padding:60px 20px;color:#666}.alert{padding:12px;border-radius:8px;margin-bottom:16px;font-size:.9rem}.alert-error{background:#7f1d1d;color:#f87171}.alert-info{background:#1e3a8a;color:#60a5fa}@media(max-width:768px){.input-group{flex-direction:column}.options{grid-template-columns:1fr}.download-header{flex-direction:column;align-items:flex-start}}</style></head><body><div class="container"><div class="header"><h1>Dwnloader</h1><p>Blazingly fast video & audio downloader</p></div><div class="input-section"><div id="alert"></div><div class="input-group"><input type="text" id="url" placeholder="Paste video or music URL..."><button class="btn-secondary" onclick="paste()">Paste</button></div><div class="options"><select id="quality" onchange="updateFormats()"><option value="720p">720p</option><option value="1080p">1080p</option><option value="1440p">1440p</option><option value="2160p">4K</option><option value="none">Best</option><option value="MUSIC">Audio</option></select><select id="format"><option value="mp4">MP4</option><option value="mkv">MKV</option><option value="webm">WebM</option></select><select id="subtitle"><option value="none">No Subs</option><option value="en">English</option><option value="es">Spanish</option><option value="fr">French</option><option value="de">German</option></select></div><button class="btn-primary" id="dlBtn" onclick="startDownload()">Download</button></div><div class="downloads"><h2>All Downloads</h2><div id="list"></div></div></div><script>const socket=io();const downloads={};const VIDEO_FORMATS=['mp4','mkv','webm','avi'];const AUDIO_FORMATS=['mp3','m4a','flac','wav','opus'];socket.on('progress',d=>{downloads[d.download_id]={...downloads[d.download_id],...d};render();});function formatBytes(b){if(!b)return'0 B';const k=1024,s=['B','KB','MB','GB'],i=Math.floor(Math.log(b)/Math.log(k));return Math.round((b/Math.pow(k,i))*100)/100+' '+s[i];}function formatTime(t){return t?new Date(t).toLocaleString():'';}async function paste(){try{document.getElementById('url').value=await navigator.clipboard.readText();}catch(e){alert('Paste manually');}}function updateFormats(){const q=document.getElementById('quality').value,f=document.getElementById('format'),formats=q==='MUSIC'?AUDIO_FORMATS:VIDEO_FORMATS;f.innerHTML=formats.map(x=>`<option value="${x}">${x.toUpperCase()}</option>`).join('');}async function startDownload(){const url=document.getElementById('url').value.trim();if(!url)return showAlert('Enter a URL','error');const btn=document.getElementById('dlBtn');btn.disabled=true;btn.textContent='Starting...';try{const res=await fetch('/api/download',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({url,quality:document.getElementById('quality').value,format:document.getElementById('format').value,subtitle_lang:document.getElementById('subtitle').value})});const data=await res.json();if(res.ok){downloads[data.download_id]={id:data.download_id,url,status:'starting',progress:0,timestamp:new Date().toISOString()};render();showAlert('Download started!','info');document.getElementById('url').value='';}else{showAlert(data.error||'Failed','error');}}catch(e){showAlert('Network error','error');}finally{btn.disabled=false;btn.textContent='Download';}}function showAlert(m,t){const a=document.getElementById('alert');a.innerHTML=`<div class="alert alert-${t}">${m}</div>`;setTimeout(()=>a.innerHTML='',4000);}function render(){const list=document.getElementById('list');const items=Object.values(downloads).sort((a,b)=>new Date(b.timestamp||0)-new Date(a.timestamp||0));if(!items.length){list.innerHTML='<div class="empty">No downloads yet</div>';return;}list.innerHTML=items.map(d=>`<div class="download-card"><div class="download-header"><div class="download-url" title="${d.filename||d.url}">${d.filename||d.url}</div><div class="status status-${d.status}">${d.status.toUpperCase()}</div></div><div class="progress-bar"><div class="progress-fill" style="width:${d.progress||0}%"></div></div><div class="download-info"><span>${d.progress||0}% - ${formatBytes(d.size||0)}</span></div>${d.timestamp?`<div style="font-size:.75rem;color:#555;margin-top:4px">Date: ${formatTime(d.timestamp)}</div>`:''}${d.status==='complete'?`<button class="btn-download" onclick="window.location.href='/api/download/${d.id}'">Download File</button>`:''}</div>`).join('');}socket.on('connect',()=>{fetch('/api/downloads').then(r=>r.json()).then(d=>Object.assign(downloads,d)).then(render);});window.onload=()=>{updateFormats();};</script></body></html>'''

@app.route('/api/check')
def check_system():
    return jsonify({'ytdlp_installed': check_ytdlp(), 'downloads': len(downloads_db), 'active': len([d for d in downloads_db.values() if d['status'] in ['downloading','converting']])})

@app.route('/api/download', methods=['POST'])
def start_download():
    data = request.json
    url = data.get('url','').strip()
    quality = data.get('quality','720p')
    subtitle_lang = data.get('subtitle_lang','none')
    output_format = data.get('format','mp4')
    
    if not url: return jsonify({'error': 'URL required'}), 400
    if not check_ytdlp(): return jsonify({'error': 'yt-dlp not installed'}), 500
    
    active = len([d for d in downloads_db.values() if d['status'] in ['downloading','converting']])
    if active >= MAX_CONCURRENT: return jsonify({'error': f'Max {MAX_CONCURRENT} concurrent downloads'}), 429
    
    download_id = str(uuid.uuid4())
    with downloads_lock:
        downloads_db[download_id] = {'id': download_id, 'url': url, 'quality': quality, 'format': output_format, 'status': 'starting', 'progress': 0, 'timestamp': datetime.now().isoformat()}
    
    threading.Thread(target=download_worker, args=(download_id, url, quality, subtitle_lang, output_format), daemon=True).start()
    return jsonify({'download_id': download_id})

@app.route('/api/download/<download_id>')
def get_file(download_id):
    with downloads_lock:
        info = downloads_db.get(download_id)
        if not info or info['status'] != 'complete':
            return jsonify({'error': 'Not ready'}), 404
        file_path = DOWNLOAD_DIR / info['filename']
        if not file_path.exists():
            return jsonify({'error': 'File missing'}), 404
        return send_file(file_path, as_attachment=True, download_name=info['filename'])

@app.route('/api/downloads')
def list_downloads():
    with downloads_lock:
        return jsonify(downloads_db)

if __name__ == '__main__':
    print("="*60)
    print("DWNLOADER - Now with perfectly clean filenames!")
    print("="*60)
    socketio.run(app, host='0.0.0.0', port=5000, debug=False)
EOF

mkdir -p downloads
chown -R dwnloader:dwnloader $INSTALL_DIR

# Rest of your original script (unchanged)
cat > /usr/local/bin/update-ytdlp.sh << 'EOFUPDATE'
#!/bin/bash
echo "[$(date +'%Y-%m-%d %H:%M:%S')] Updating yt-dlp..."
curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
chmod a+rx /usr/local/bin/yt-dlp
echo "[$(date +'%Y-%m-%d %H:%M:%S')] yt-dlp updated"
EOFUPDATE
chmod a+rx /usr/local/bin/update-ytdlp.sh

cat > /etc/cron.daily/update-ytdlp << 'EOFCRON'
#!/bin/bash
/usr/local/bin/update-ytdlp.sh >> /var/log/ytdlp-update.log 2>&1
EOFCRON
chmod a+rx /etc/cron.daily/update-ytdlp

if [ "$UPDATING" = false ]; then
    cat > /etc/systemd/system/$SERVICE_NAME.service << EOF
[Unit]
Description=Dwnloader - Video/Audio Downloader Service
After=network.target

[Service]
Type=simple
User=dwnloader
Group=dwnloader
WorkingDirectory=$INSTALL_DIR
Environment="PATH=$INSTALL_DIR/venv/bin:/usr/local/bin:/usr/bin"
Environment="DOWNLOAD_DIR=$INSTALL_DIR/downloads"
Environment="MAX_CONCURRENT=3"
Environment="CLEANUP_HOURS=24"
ExecStart=$INSTALL_DIR/venv/bin/python app.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload
[ "$UPDATING" = false ] && systemctl enable $SERVICE_NAME
systemctl start $SERVICE_NAME

sleep 2
echo ""
echo "=================================================="
[ "$UPDATING" = true ] && echo "UPDATE Complete! (Clean filenames now working)" || echo "INSTALLATION Complete!"
echo "=================================================="
echo "Access: http://$(hostname -I | awk '{print $1}'):5000"
echo "Status: systemctl status $SERVICE_NAME"
echo "=================================================="
