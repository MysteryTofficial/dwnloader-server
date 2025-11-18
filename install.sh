#!/bin/bash

# Dwnloader - Ubuntu Server Installation Script
# Run with: sudo bash install.sh

set -e

echo "=================================================="
echo "⚡ DWNLOADER - Installation Script"
echo "=================================================="

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "❌ Please run as root (use sudo)"
    exit 1
fi

echo "📦 Installing system dependencies..."
apt-get update
apt-get install -y python3 python3-pip python3-venv ffmpeg curl

echo "📥 Installing yt-dlp..."
curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
chmod a+rx /usr/local/bin/yt-dlp

echo "👤 Creating dwnloader user..."
if ! id -u dwnloader &>/dev/null; then
    useradd -r -m -s /bin/bash dwnloader
fi

echo "📁 Setting up application directory..."
INSTALL_DIR="/opt/dwnloader"
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

echo "🐍 Creating Python virtual environment..."
python3 -m venv venv
source venv/bin/activate

echo "📦 Installing Python dependencies..."
pip install --upgrade pip
pip install flask flask-socketio eventlet

echo "📝 Creating app.py..."
cat > app.py << 'EOFAPP'
"""
Dwnloader - Blazingly Fast Multi-User Video/Audio Downloader
Optimized version with shared downloads view
"""

from flask import Flask, request, jsonify, send_file
from flask_socketio import SocketIO, emit
import os
import subprocess
import json
import uuid
import threading
import time
import re
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

def download_worker(download_id, url, quality, subtitle_lang, output_format):
    try:
        with downloads_lock:
            downloads_db[download_id]['status'] = 'downloading'
        
        socketio.emit('progress', {
            'download_id': download_id,
            'progress': 0,
            'status': 'downloading'
        }, broadcast=True)
        
        cmd = [
            YTDLP_EXEC,
            '--no-playlist',
            '--no-warnings',
            '--progress',
            '--newline'
        ]
        
        if quality == "MUSIC":
            cmd.extend([
                '-x',
                '--audio-format', output_format,
                '--audio-quality', '0',
                '--embed-thumbnail',
                '--add-metadata'
            ])
            output_template = str(DOWNLOAD_DIR / f"{get_url_hash(url)}_%(title).60s.{output_format}")
        else:
            if quality != "none":
                height = quality.replace("p", "")
                cmd.extend(['-f', f'bestvideo[height<={height}][ext=mp4]+bestaudio[ext=m4a]/best[height<={height}]'])
            else:
                cmd.extend(['-f', 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best'])
            
            if subtitle_lang != "none":
                cmd.extend(['--write-subs', '--sub-langs', subtitle_lang, '--embed-subs'])
            
            cmd.extend(['--merge-output-format', output_format])
            output_template = str(DOWNLOAD_DIR / f"{get_url_hash(url)}_%(title).60s.{output_format}")
        
        cmd.extend(['-o', output_template, url])
        
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1
        )
        
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
                        socketio.emit('progress', {
                            'download_id': download_id,
                            'progress': progress,
                            'status': 'downloading'
                        }, broadcast=True)
            
            elif any(x in line for x in ['[ffmpeg]', 'Merging', 'Converting']):
                with downloads_lock:
                    downloads_db[download_id]['status'] = 'converting'
                socketio.emit('progress', {
                    'download_id': download_id,
                    'progress': 95,
                    'status': 'converting'
                }, broadcast=True)
        
        process.wait()
        
        if process.returncode == 0:
            files = list(DOWNLOAD_DIR.glob(f"{get_url_hash(url)}_*.{output_format}"))
            if files:
                newest_file = max(files, key=lambda x: x.stat().st_mtime)
                filename = newest_file.name
                
                with downloads_lock:
                    downloads_db[download_id]['status'] = 'complete'
                    downloads_db[download_id]['filename'] = filename
                    downloads_db[download_id]['progress'] = 100
                    downloads_db[download_id]['size'] = newest_file.stat().st_size
                
                socketio.emit('progress', {
                    'download_id': download_id,
                    'progress': 100,
                    'status': 'complete',
                    'filename': filename,
                    'size': newest_file.stat().st_size
                }, broadcast=True)
            else:
                raise Exception("Downloaded file not found")
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
        }, broadcast=True)

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
                to_remove = [
                    dl_id for dl_id, info in downloads_db.items()
                    if info.get('status') == 'complete' and 
                    datetime.fromisoformat(info['timestamp']).timestamp() < cutoff
                ]
                for dl_id in to_remove:
                    del downloads_db[dl_id]
        
        except Exception as e:
            print(f"[CLEANUP ERROR] {e}")
        
        time.sleep(1800)

cleanup_thread = threading.Thread(target=cleanup_worker, daemon=True)
cleanup_thread.start()

@app.route('/')
def index():
    return '''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Dwnloader</title>
    <script src="https://cdn.socket.io/4.5.4/socket.io.min.js"></script>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0a0a0a; color: #e0e0e0; min-height: 100vh; padding: 20px; }
        .container { max-width: 1200px; margin: 0 auto; }
        .header { text-align: center; margin-bottom: 40px; padding: 20px; background: linear-gradient(135deg, #1a1a1a 0%, #2a2a2a 100%); border-radius: 12px; border: 1px solid #333; }
        .header h1 { font-size: 2rem; margin-bottom: 8px; background: linear-gradient(135deg, #60a5fa 0%, #a78bfa 100%); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
        .header p { color: #888; font-size: 0.9rem; }
        .input-section { background: #1a1a1a; padding: 24px; border-radius: 12px; margin-bottom: 24px; border: 1px solid #333; }
        .input-group { display: flex; gap: 12px; margin-bottom: 16px; }
        input, select { background: #0a0a0a; border: 1px solid #333; color: #e0e0e0; padding: 12px; border-radius: 8px; font-size: 0.95rem; transition: all 0.2s; }
        input:focus, select:focus { outline: none; border-color: #60a5fa; box-shadow: 0 0 0 2px rgba(96, 165, 250, 0.1); }
        input[type="text"] { flex: 1; }
        .options { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; margin-bottom: 16px; }
        button { padding: 12px 24px; border: none; border-radius: 8px; font-size: 0.95rem; font-weight: 600; cursor: pointer; transition: all 0.2s; }
        .btn-primary { background: linear-gradient(135deg, #60a5fa 0%, #a78bfa 100%); color: white; width: 100%; }
        .btn-primary:hover { transform: translateY(-2px); box-shadow: 0 4px 12px rgba(96, 165, 250, 0.4); }
        .btn-primary:disabled { opacity: 0.5; cursor: not-allowed; transform: none; }
        .btn-secondary { background: #2a2a2a; color: #e0e0e0; }
        .btn-secondary:hover { background: #333; }
        .downloads { background: #1a1a1a; border-radius: 12px; padding: 24px; border: 1px solid #333; }
        .downloads h2 { margin-bottom: 20px; font-size: 1.3rem; }
        .download-card { background: #0a0a0a; border: 1px solid #333; border-radius: 8px; padding: 16px; margin-bottom: 12px; transition: all 0.2s; }
        .download-card:hover { border-color: #444; transform: translateX(4px); }
        .download-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; gap: 12px; }
        .download-url { flex: 1; color: #888; font-size: 0.85rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .status { padding: 4px 12px; border-radius: 12px; font-size: 0.75rem; font-weight: 600; white-space: nowrap; }
        .status-downloading { background: #1e3a8a; color: #60a5fa; }
        .status-converting { background: #581c87; color: #a78bfa; }
        .status-complete { background: #065f46; color: #34d399; }
        .status-error { background: #7f1d1d; color: #f87171; }
        .progress-bar { height: 4px; background: #2a2a2a; border-radius: 2px; overflow: hidden; margin-bottom: 12px; }
        .progress-fill { height: 100%; background: linear-gradient(90deg, #60a5fa 0%, #a78bfa 100%); transition: width 0.3s; }
        .download-info { display: flex; justify-content: space-between; font-size: 0.8rem; color: #666; margin-bottom: 8px; }
        .btn-download { background: #065f46; color: #34d399; width: 100%; }
        .btn-download:hover { background: #047857; }
        .empty { text-align: center; padding: 60px 20px; color: #666; }
        .alert { padding: 12px; border-radius: 8px; margin-bottom: 16px; font-size: 0.9rem; }
        .alert-error { background: #7f1d1d; color: #f87171; }
        .alert-info { background: #1e3a8a; color: #60a5fa; }
        @media (max-width: 768px) { .input-group { flex-direction: column; } .options { grid-template-columns: 1fr; } .download-header { flex-direction: column; align-items: flex-start; } }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>⚡ Dwnloader</h1>
            <p>Blazingly fast video & audio downloader</p>
        </div>
        <div class="input-section">
            <div id="alert"></div>
            <div class="input-group">
                <input type="text" id="url" placeholder="Paste video or music URL...">
                <button class="btn-secondary" onclick="paste()">📋</button>
            </div>
            <div class="options">
                <select id="quality" onchange="updateFormats()">
                    <option value="720p">720p</option>
                    <option value="1080p">1080p</option>
                    <option value="1440p">1440p</option>
                    <option value="2160p">4K</option>
                    <option value="none">Best</option>
                    <option value="MUSIC">🎵 Audio</option>
                </select>
                <select id="format">
                    <option value="mp4">MP4</option>
                    <option value="mkv">MKV</option>
                    <option value="webm">WebM</option>
                </select>
                <select id="subtitle">
                    <option value="none">No Subs</option>
                    <option value="en">English</option>
                    <option value="es">Spanish</option>
                    <option value="fr">French</option>
                    <option value="de">German</option>
                </select>
            </div>
            <button class="btn-primary" id="dlBtn" onclick="startDownload()">⬇ Download</button>
        </div>
        <div class="downloads">
            <h2>All Downloads</h2>
            <div id="list"></div>
        </div>
    </div>
    <script>
        const socket = io();
        const downloads = {};
        const VIDEO_FORMATS = ['mp4', 'mkv', 'webm', 'avi'];
        const AUDIO_FORMATS = ['mp3', 'm4a', 'flac', 'wav', 'opus'];
        socket.on('progress', (data) => { downloads[data.download_id] = { ...downloads[data.download_id], ...data }; render(); });
        async function paste() { try { document.getElementById('url').value = await navigator.clipboard.readText(); } catch (e) { alert('Paste manually or grant clipboard permission'); } }
        function updateFormats() { const quality = document.getElementById('quality').value; const formatSelect = document.getElementById('format'); const formats = quality === 'MUSIC' ? AUDIO_FORMATS : VIDEO_FORMATS; formatSelect.innerHTML = formats.map(f => `<option value="${f}">${f.toUpperCase()}</option>`).join(''); }
        async function startDownload() { const url = document.getElementById('url').value.trim(); if (!url) return showAlert('Enter a URL', 'error'); const btn = document.getElementById('dlBtn'); btn.disabled = true; btn.textContent = 'Starting...'; try { const res = await fetch('/api/download', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ url, quality: document.getElementById('quality').value, format: document.getElementById('format').value, subtitle_lang: document.getElementById('subtitle').value }) }); const data = await res.json(); if (res.ok) { downloads[data.download_id] = { id: data.download_id, url, status: 'starting', progress: 0 }; render(); showAlert('Download started!', 'info'); document.getElementById('url').value = ''; } else { showAlert(data.error || 'Failed', 'error'); } } catch (e) { showAlert('Network error', 'error'); } finally { btn.disabled = false; btn.textContent = '⬇ Download'; } }
        function showAlert(msg, type) { const alert = document.getElementById('alert'); alert.innerHTML = `<div class="alert alert-${type}">${msg}</div>`; setTimeout(() => alert.innerHTML = '', 4000); }
        function formatSize(bytes) { if (!bytes) return ''; const mb = bytes / (1024 * 1024); return mb > 1 ? `${mb.toFixed(1)} MB` : `${(bytes / 1024).toFixed(0)} KB`; }
        function render() { const list = document.getElementById('list'); const items = Object.values(downloads).reverse(); if (items.length === 0) { list.innerHTML = '<div class="empty">No downloads yet</div>'; return; } list.innerHTML = items.map(d => `<div class="download-card"><div class="download-header"><div class="download-url" title="${d.url}">${d.url}</div><div class="status status-${d.status}">${d.status.toUpperCase()}</div></div><div class="progress-bar"><div class="progress-fill" style="width: ${d.progress || 0}%"></div></div><div class="download-info"><span>${d.progress || 0}%</span><span>${formatSize(d.size)}</span></div>${d.status === 'complete' ? `<button class="btn-download" onclick="download('${d.id}')">💾 Download ${d.filename}</button>` : ''}</div>`).join(''); }
        function download(id) { window.location.href = `/api/download/${id}`; }
        async function loadDownloads() { try { const res = await fetch('/api/downloads'); const data = await res.json(); Object.assign(downloads, data); render(); } catch (e) { console.error('Failed to load downloads', e); } }
        socket.on('connect', loadDownloads);
        window.onload = () => { updateFormats(); loadDownloads(); };
    </script>
</body>
</html>'''

@app.route('/api/check')
def check_system():
    return jsonify({
        'ytdlp_installed': check_ytdlp(),
        'downloads': len(downloads_db),
        'active': len([d for d in downloads_db.values() if d['status'] in ['downloading', 'converting']])
    })

@app.route('/api/download', methods=['POST'])
def start_download():
    data = request.json
    url = data.get('url', '').strip()
    quality = data.get('quality', '720p')
    subtitle_lang = data.get('subtitle_lang', 'none')
    output_format = data.get('format', 'mp4')
    
    if not url:
        return jsonify({'error': 'URL required'}), 400
    
    if not check_ytdlp():
        return jsonify({'error': 'yt-dlp not installed'}), 500
    
    active = len([d for d in downloads_db.values() if d['status'] in ['downloading', 'converting']])
    if active >= MAX_CONCURRENT:
        return jsonify({'error': f'Max {MAX_CONCURRENT} concurrent downloads'}), 429
    
    download_id = str(uuid.uuid4())
    
    with downloads_lock:
        downloads_db[download_id] = {
            'id': download_id,
            'url': url,
            'quality': quality,
            'format': output_format,
            'status': 'starting',
            'progress': 0,
            'timestamp': datetime.now().isoformat()
        }
    
    thread = threading.Thread(
        target=download_worker,
        args=(download_id, url, quality, subtitle_lang, output_format),
        daemon=True
    )
    thread.start()
    
    return jsonify({'download_id': download_id})

@app.route('/api/download/<download_id>')
def get_file(download_id):
    with downloads_lock:
        if download_id not in downloads_db:
            return jsonify({'error': 'Not found'}), 404
        download_info = downloads_db[download_id]
    
    if download_info['status'] != 'complete':
        return jsonify({'error': 'Not ready'}), 400
    
    file_path = DOWNLOAD_DIR / download_info['filename']
    
    if not file_path.exists():
        return jsonify({'error': 'File not found'}), 404
    
    return send_file(file_path, as_attachment=True)

@app.route('/api/downloads')
def list_downloads():
    with downloads_lock:
        return jsonify(downloads_db)

if __name__ == '__main__':
    print("=" * 60)
    print("⚡ DWNLOADER - Blazingly Fast Downloader")
    print("=" * 60)
    print(f"🌐 URL: http://localhost:5000")
    print(f"📁 Downloads: {DOWNLOAD_DIR.absolute()}")
    print(f"✅ yt-dlp: {'Installed' if check_ytdlp() else 'NOT INSTALLED'}")
    print(f"⚡ Max Concurrent: {MAX_CONCURRENT}")
    print("=" * 60)
    
    socketio.run(app, host='0.0.0.0', port=5000, debug=False)
EOFAPP

echo "📁 Creating downloads directory..."
mkdir -p downloads

echo "🔧 Setting permissions..."
chown -R dwnloader:dwnloader $INSTALL_DIR

echo "🚀 Creating systemd service..."
cat > /etc/systemd/system/dwnloader.service << EOF
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

echo "🕒 Setting up daily yt-dlp auto-update..."

# Create update script
cat > /usr/local/bin/update-ytdlp << 'EOFUPD'
#!/bin/bash
set -e
curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
chmod a+rx /usr/local/bin/yt-dlp
EOFUPD

chmod +x /usr/local/bin/update-ytdlp

# Systemd service
cat > /etc/systemd/system/ytdlp-update.service << 'EOFSVC'
[Unit]
Description=Update yt-dlp to latest version

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-ytdlp
EOFSVC

# Systemd timer
cat > /etc/systemd/system/ytdlp-update.timer << 'EOFTMR'
[Unit]
Description=Run yt-dlp update daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOFTMR

# Enable + start timer
systemctl daemon-reload
systemctl enable --now ytdlp-update.timer

echo "✅ Daily auto-update for yt-dlp is now active!"


echo "🔄 Reloading systemd..."
systemctl daemon-reload

echo "✅ Enabling service..."
systemctl enable dwnloader

echo "🚀 Starting service..."
systemctl start dwnloader

echo ""
echo "=================================================="
echo "✅ Installation Complete!"
echo "=================================================="
echo ""
echo "📍 Service Status:"
systemctl status dwnloader --no-pager
echo ""
echo "🌐 Access: http://YOUR_SERVER_IP:5000"
echo ""
echo "📋 Useful Commands:"
echo "  sudo systemctl status dwnloader   # Check status"
echo "  sudo systemctl restart dwnloader  # Restart"
echo "  sudo systemctl stop dwnloader     # Stop"
echo "  sudo systemctl logs -f dwnloader  # View logs"
echo "  sudo journalctl -u dwnloader -f   # Detailed logs"
echo ""
echo "📁 Files located at: $INSTALL_DIR"
echo "=================================================="
