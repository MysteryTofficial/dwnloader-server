#!/bin/bash
# ╔══════════════════════════════════════════════════════════╗
# ║           DWNLOADER — Final Perfect Edition v4.0         ║
# ║   Real-time progress • MP3 default • Clean titles        ║
# ╚══════════════════════════════════════════════════════════╝

set -e

R='\033[1;31m' G='\033[1;32m' B='\033[1;34m' Y='\033[1;33m' C='\033[1;36m' P='\033[1;35m' W='\033[1;37m' NC='\033[0m'
OK="$G✓$NC" FAIL="$R✗$NC" WAIT="$Y◷$NC" FIRE="$P⚡$NC" ROCKET="$C🚀$NC" SPARK="$P✨$NC" MUSIC="$P🎵$NC"

clear
echo -e "${P} ______            _        _        _______  _______  ______   _______  _______ "
echo -e "${P}(  __  \ |\     /|( (    /|( \      (  ___  )(  ___  )(  __  \ (  ____ \(  ____ )"
echo -e "${P}| (  \  )| )   ( ||  \  ( || (      | (   ) || (   ) || (  \  )| (    \/| (    )|"
echo -e "${P}| |   ) || | _ | ||   \ | || |      | |   | || (___) || |   ) || (__    | (____)|"
echo -e "${P}| |   | || |( )| || (\ \) || |      | |   | ||  ___  || |   | ||  __)   |     __)"
echo -e "${P}| |   ) || || || || | \   || |      | |   | || (   ) || |   ) || (      | (\ (   "
echo -e "${P}| (__/  )| () () || )  \  || (____/\| (___) || )   ( || (__/  )| (____/\| ) \ \__"
echo -e "${P}(______/ (_______)|/    )_)(_______/(_______)|/     \|(______/ (_______/|/   \__/${C}v4.0$NC"
echo -e "${W}        Real-time progress • MP3 by default • Clean titles$NC"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "$FAIL ${R}Run with sudo! →${W} sudo bash $0${NC}"; exit 1
fi

INSTALL_DIR="/opt/dwnloader"
SERVICE="dwnloader"
UPDATING=false

echo -e "$WAIT ${Y}Checking installation...$NC"
sleep 1
if [ -d "$INSTALL_DIR" ]; then
    UPDATING=true
    echo -e "$OK ${G}Update mode — your downloads are safe!$NC"
    systemctl stop $SERVICE 2>/dev/null || true
else
    echo -e "$OK ${C}Fresh install — let's go!$NC"
fi

echo -e "\n$WAIT ${B}Installing dependencies...$NC"
apt-get update -qq > /dev/null
apt-get install -y python3 python3-pip python3-venv ffmpeg curl > /dev/null 2>&1
echo -e "$OK ${G}Dependencies ready$NC"

echo -e "$WAIT ${B}Updating yt-dlp...$NC"
curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp --silent
chmod a+rx /usr/local/bin/yt-dlp
echo -e "$OK ${G}yt-dlp updated$NC"

mkdir -p $INSTALL_DIR/downloads
useradd -r -m -s /bin/bash dwnloader 2>/dev/null || true
chown -R dwnloader:dwnloader $INSTALL_DIR 2>/dev/null || true
cd $INSTALL_DIR

if [ "$UPDATING" = true ]; then
    [ -f app.py ] && cp app.py app.py.backup.$(date +%Y%m%d_%H%M%S)
fi

[ ! -d venv ] && python3 -m venv venv > /dev/null 2>&1
source venv/bin/activate
pip install --quiet --upgrade pip flask flask-socketio eventlet > /dev/null 2>&1

echo -e "$WAIT ${P}Deploying Dwnloader v4.0 — Real-time + MP3 default...$NC"
cat > app.py << 'EOF'
from flask import Flask, request, jsonify, send_file
from flask_socketio import SocketIO
import os, subprocess, uuid, threading, time, re, unicodedata, hashlib
from pathlib import Path
from datetime import datetime

app = Flask(__name__)
app.config['SECRET_KEY'] = os.getenv('SECRET_KEY', str(uuid.uuid4()))
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='eventlet', ping_timeout=60, ping_interval=25)

DOWNLOAD_DIR = Path("downloads")
YTDLP = "yt-dlp"
MAX_CONCURRENT = 4
db, lock = {}, threading.Lock()

def hsh(url): return hashlib.md5(url.encode()).hexdigest()[:12]
def clean(name):
    n = name.rsplit('.', 1)[0] if '.' in name else name
    n = unicodedata.normalize('NFKD', n)
    n = ''.join(c for c in n if c.isascii() and (c.isalnum() or c in ' -_'))
    n = ' '.join(n.split()).strip(' -_')
    return n or 'download'

def worker(did, url, quality, subs, fmt):
    try:
        with lock: db[did]['status'] = 'downloading'; db[did]['progress'] = 0
        socketio.emit('progress', {'download_id': did, 'progress': 0, 'status': 'downloading'})

        cmd = [YTDLP, '--no-playlist', '--no-warnings', '--newline']
        template = str(DOWNLOAD_DIR / f"{hsh(url)}_%(title).60s.%(ext)s")

        if quality == "MUSIC":
            cmd += ['-x', '--audio-format', fmt, '--audio-quality', '0', '--embed-thumbnail', '--add-metadata']
        else:
            if quality != "none":
                h = quality.replace("p", "")
                cmd += ['-f', f'bestvideo[height<={h}]+bestaudio/best[height<={h}]']
            if subs != "none":
                cmd += ['--write-subs', '--sub-langs', subs, '--embed-subs']
            cmd += ['--merge-output-format', fmt]
        cmd += ['-o', template, url]

        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        last = 0
        for line in proc.stdout:
            if '[download]' in line and '%' in line:
                m = re.search(r'(\d+(?:\.\d+)?)%', line)
                if m:
                    p = int(float(m.group(1)))
                    if p - last >= 3 or p == 100:
                        last = p
                        with lock: db[did]['progress'] = p
                        socketio.emit('progress', {'download_id': did, 'progress': p, 'status': 'downloading'})
            elif '[ffmpeg]' in line or 'Merging' in line:
                with lock: db[did]['status'] = 'converting'
                socketio.emit('progress', {'download_id': did, 'progress': 95, 'status': 'converting'})

        proc.wait()
        if proc.returncode != 0: raise Exception("yt-dlp failed")

        files = list(DOWNLOAD_DIR.glob(f"{hsh(url)}_*.{fmt}"))
        if not files: raise Exception("File missing")
        src = max(files, key=lambda x: x.stat().st_mtime)

        new_name = clean(src.stem[len(hsh(url))+1:]) + f".{fmt}"
        dst = DOWNLOAD_DIR / new_name
        if not dst.exists():
            src.rename(dst)

        size = dst.stat().st_size
        with lock:
            db[did].update({'status': 'complete', 'filename': dst.name, 'size': size, 'progress': 100,
                           'timestamp': datetime.now().isoformat()})
        socketio.emit('progress', {'download_id': did, 'progress': 100, 'status': 'complete',
                                  'filename': dst.name, 'size': size})

    except Exception as e:
        with lock: db[did]['status'] = 'error'; db[did]['error'] = str(e)
        socketio.emit('progress', {'download_id': did, 'status': 'error', 'error': str(e)})

def cleanup():
    while True:
        time.sleep(3600)
        cutoff = time.time() - 48*3600
        for f in DOWNLOAD_DIR.glob('*'):
            if f.is_file() and f.stat().st_mtime < cutoff:
                f.unlink(missing_ok=True)
        with lock:
            for k in list(db):
                if db[k].get('status') == 'complete':
                    try:
                        if datetime.fromisoformat(db[k]['timestamp']).timestamp() < cutoff:
                            del db[k]
                    except: pass
threading.Thread(target=cleanup, daemon=True).start()

@app.route('/')
def index():
    return '''<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Dwnloader</title>
<script src="https://cdn.socket.io/4.7.5/socket.io.min.js"></script>
<style>
  body{font-family:system-ui;background:#0d0d0d;color:#eee;margin:0;padding:20px}
  .c{max-width:900px;margin:auto;background:#111;padding:30px;border-radius:16px;border:1px solid #333}
  h1{font-size:2.5em;background:linear-gradient(90deg,#8b5cf6,#3b82f6);-webkit-background-clip:text;color:transparent}
  input,select,button{padding:14px;border-radius:12px;border:none;font-size:1em;margin:8px 0}
  input,select{background:#222;color:#fff;flex:1}
  button{background:linear-gradient(90deg,#8b5cf6,#3b82f6);color:#fff;cursor:pointer;font-weight:bold}
  button:hover{transform:scale(1.05);transition:.2s}
  .opts{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px}
  .dl{background:#222;padding:16px;margin:12px 0;border-radius:12px;border:1px solid #444}
  .bar{height:6px;background:#333;border-radius:3px;overflow:hidden;margin:10px 0}
  .fill{height:100%;background:linear-gradient(90deg,#8b5cf6,#3b82f6);width:0%;transition:width .4s}
  .status{padding:4px 12px;border-radius:20px;font-size:.8em;font-weight:bold}
  .complete{background:#166534;color:#4ade80}
  .downloading{background:#1e40af;color:#60a5fa}
  .converting{background:#7c2d12;color:#fb923c}
  .error{background:#7f1d1d;color:#fca5a5}
</style></head><body>
<div class="c">
  <h1>Dwnloader</h1>
  <p>Just paste any link — MP3 is default</p>
  <div style="display:flex;gap:10px"><input type="text" id="url" placeholder="YouTube, TikTok, Instagram, SoundCloud...">
  <button onclick="navigator.clipboard.readText().then(t=>document.getElementById('url').value=t)">Paste</button></div>
  <div class="opts">
    <select id="q" onchange="f.value=q.value==='MUSIC'?['mp3','m4a','opus','flac']:['mp4','mkv','webm'];f.innerHTML=f.value.map(x=>`<option value=${x} ${x==='mp3'&&q.value==='MUSIC'?'selected':''}>${x.toUpperCase()}</option>`).join('')">
      <option value="MUSIC" selected>Audio Only</option>
      <option value="720p">720p</option>
      <option value="1080p">1080p</option>
      <option value="2160p">4K</option>
      <option value="none">Best Video</option>
    </select>
    <select id="f"><option value="mp3" selected>MP3</option><option value="m4a">M4A</option><option value="opus">OPUS</option><option value="flac">FLAC</option></select>
    <select id="s"><option value="none">No Subs</option><option value="en">English</option></select>
  </div>
  <button style="width:100%;padding:16px;margin-top:12px" onclick="start()">Download Now</button>
  <div id="list" style="margin-top:30px"></div>
</div>
<script>
const socket=io(), d={}, q=document.getElementById('q'), f=document.getElementById('f');
function start(){
  const url=document.getElementById('url').value.trim();
  if(!url)return;
  fetch('/api/start',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({url,quality:q.value,format:f.value,subtitle_lang:document.getElementById('s').value})
  }).then(r=>r.json()).then(res=>{
    if(res.download_id){
      d[res.download_id]={id:res.download_id,url,status:'starting',progress:0,filename:url};
      render();
      document.getElementById('url').value='';
    }
  });
}
function render(){
  const list=document.getElementById('list');
  const items=Object.values(d).sort((a,b)=> (b.timestamp||0)-(a.timestamp||0));
  list.innerHTML=items.map(i=>`
    <div class="dl">
      <div style="display:flex;justify-content:space-between;align-items:center">
        <div style="flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${i.filename||i.url}">
          ${i.filename||i.url}
        </div>
        <span class="status ${i.status}">${i.status.toUpperCase()}</span>
      </div>
      <div class="bar"><div class="fill" style="width:${i.progress||0}%"></div></div>
      <small>${i.progress||0}% • ${i.size?((i.size/1024/1024).toFixed(1)+' MB'):'—'}</small>
      ${i.status==='complete'?` <button onclick="location.href='/api/get/${i.id}'" style="float:right;padding:8px 16px;margin-top:8px">Download File</button>`:''}
    </div>
  `).join('') || '<p style="text-align:center;color:#666">No downloads yet — paste a link above!</p>';
}
socket.on('progress', p=>{ if(d[p.download_id]){ Object.assign(d[p.download_id], p); render(); } });
socket.on('connect', ()=> fetch('/api/list').then(r=>r.json()).then(data=>{ Object.assign(d,data); render(); }));
q.onchange(); render();
</script></body></html>'''

@app.route('/api/start', methods=['POST'])
def start():
    data = request.json
    url = data.get('url','').strip()
    if not url: return jsonify(error="No URL"), 400
    did = str(uuid.uuid4())
    with lock:
        db[did] = {'id':did,'url':url,'status':'starting','progress':0,'timestamp':datetime.now().isoformat()}
    threading.Thread(target=worker, args=(did, url, data.get('quality','MUSIC'), data.get('subtitle_lang','none'), data.get('format','mp3')), daemon=True).start()
    return jsonify(download_id=did)

@app.route('/api/get/<did>')
def get(did):
    with lock:
        info = db.get(did)
        if not info or info['status'] != 'complete': return "Not ready", 404
        path = DOWNLOAD_DIR / info['filename']
        if not path.exists(): return "File gone", 404
        return send_file(path, as_attachment=True, download_name=info['filename'])

@app.route('/api/list')
def list(): 
    with lock: return jsonify(db)

if __name__ == '__main__':
    print("Dwnloader v4.0 started — http://0.0.0.0:5000")
    socketio.run(app, host='0.0.0.0', port=5000)
EOF
echo -e "$OK ${P}Dwnloader v4.0 deployed — real-time progress fixed!$NC"

cat > /usr/local/bin/update-ytdlp.sh << 'EOF'
#!/bin/bash
echo "[$(date)] Updating yt-dlp..." >> /var/log/ytdlp-update.log
curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp -s
chmod a+rx /usr/local/bin/yt-dlp
echo "[$(date)] yt-dlp updated" >> /var/log/ytdlp-update.log
EOF
chmod +x /usr/local/bin/update-ytdlp.sh
(crontab -l 2>/dev/null | grep -v update-ytdlp; echo "17 4 * * * /usr/local/bin/update-ytdlp.sh") | crontab -

cat > /etc/systemd/system/$SERVICE.service << EOF
[Unit]
Description=Dwnloader v4.0 — Real-time MP3 Downloader
After=network.target
[Service]
Type=simple
User=dwnloader
WorkingDirectory=$INSTALL_DIR
Environment="PATH=$INSTALL_DIR/venv/bin:/usr/local/bin:/usr/bin"
ExecStart=$INSTALL_DIR/venv/bin/python app.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now $SERVICE > /dev/null 2>&1
sleep 3

IP=$(hostname -I | awk '{print $1}')

clear
echo -e "${P} ______            _        _        _______  _______  ______   _______  _______ "
echo -e "${P}(  __  \ |\     /|( (    /|( \      (  ___  )(  ___  )(  __  \ (  ____ \(  ____ )"
echo -e "${P}| (  \  )| )   ( ||  \  ( || (      | (   ) || (   ) || (  \  )| (    \/| (    )|"
echo -e "${P}| |   ) || | _ | ||   \ | || |      | |   | || (___) || |   ) || (__    | (____)|"
echo -e "${P}| |   | || |( )| || (\ \) || |      | |   | ||  ___  || |   | ||  __)   |     __)"
echo -e "${P}| |   ) || || || || | \   || |      | |   | || (   ) || |   ) || (      | (\ (   "
echo -e "${P}| (__/  )| () () || )  \  || (____/\| (___) || )   ( || (__/  )| (____/\| ) \ \__"
echo -e "${P}(______/ (_______)|/    )_)(_______/(_______)|/     \|(______/ (_______/|/   \__/${C}v4.0$NC"
echo -e ""
echo -e "   ${G}Installation complete!${NC}"
echo -e ""
echo -e "   ${ROCKET} Open now → ${W}http://$IP:5000${NC}"
echo -e "   ${MUSIC} Default: MP3 + Audio (just paste any link!)"
echo -e "   ${FIRE} Real-time progress bar — no refresh needed"
echo -e "   ${SPARK} Clean beautiful filenames every time"
echo -e ""
echo -e "   ${C}Enjoy the best downloader ever made.${NC}"
echo -e ""
