# ⚡ Dwnloader Server

**Blazingly Fast Multi-User Video & Audio Downloader**
Optimized for Ubuntu servers with shared downloads view and real-time progress tracking.

![Dwnloader](https://img.shields.io/badge/Dwnloader-v1.0-blue?style=flat-square)

---

## Features

* Multi-user, multi-download support
* Real-time download progress via WebSocket
* Audio and video downloads in multiple formats
* Automatic cleanup of old files
* Lightweight Flask + Python environment
* Systemd service for background operation

---

## Installation

Run the installer on Ubuntu Server:

```bash
curl -sSL https://raw.githubusercontent.com/MysteryTofficial/dwnloader-server/refs/heads/main/install.sh | sudo bash
```

The script will:

1. Install required system dependencies: Python 3, pip, virtualenv, ffmpeg, curl
2. Install `yt-dlp` globally
3. Create a dedicated `dwnloader` user
4. Set up application directory at `/opt/dwnloader`
5. Create a Python virtual environment and install Python dependencies (`flask`, `flask-socketio`, `eventlet`)
6. Create `app.py` with full downloader logic
7. Configure a systemd service for automatic startup

---

## Access

After installation, open in your browser:

```
http://YOUR_SERVER_IP:5000
```

---

## Usage

1. Paste video/audio URL into the input box
2. Choose desired **quality** and **format**
3. Select **subtitle language** (optional)
4. Click **⬇ Download**
5. Monitor progress in real-time and download completed files

---

## API Endpoints

* `GET /api/check` – Check system status and active downloads
* `POST /api/download` – Start a new download
* `GET /api/download/<download_id>` – Fetch completed file
* `GET /api/downloads` – List all downloads

---

## Systemd Service

Dwnloader runs as a systemd service:

```bash
# Check status
sudo systemctl status dwnloader

# Start service
sudo systemctl start dwnloader

# Stop service
sudo systemctl stop dwnloader

# Restart service
sudo systemctl restart dwnloader

# Follow logs
sudo systemctl logs -f dwnloader
sudo journalctl -u dwnloader -f
```

Service runs under user `dwnloader` and stores files at:

```
/opt/dwnloader/downloads
```

---

## Configuration

Environment variables can be set in `/etc/systemd/system/dwnloader.service`:

* `DOWNLOAD_DIR` – Directory for downloads (`/opt/dwnloader/downloads` by default)
* `MAX_CONCURRENT` – Maximum simultaneous downloads (default: `3`)
* `CLEANUP_HOURS` – Time in hours to keep old files (default: `24`)

---

## Dependencies

* Python 3
* pip
* virtualenv
* ffmpeg
* curl
* yt-dlp

Python packages installed inside virtual environment:

* Flask
* Flask-SocketIO
* Eventlet

---

## Screenshots

![UI Screenshot](https://user-images.githubusercontent.com/yourusername/dwnloader-screenshot.png)
*Real-time download progress, video/audio formats, and subtitle support.*

