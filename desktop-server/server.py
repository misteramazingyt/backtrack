#!/usr/bin/env python3
"""Backtrack desktop server.

Runs on the desktop (Windows/macOS/Linux) and does the heavy lifting the
iPhone can't: downloads a Spotify track with spotdl, isolates the
instrumental with UVR (the ../uvr repo), encodes it to m4a with ffmpeg,
and serves it to the Backtrack iOS app over the tailnet.

Run inside the venv created by setup.ps1 (Python 3.11):

    .venv\\Scripts\\python server.py --port 8790 --token pick-a-secret

Optional Spotify "currently playing" support (needs a free Spotify
developer app; see README):

    $env:SPOTIPY_CLIENT_ID = "..."
    $env:SPOTIPY_CLIENT_SECRET = "..."
    .venv\\Scripts\\python server.py --port 8790 --token pick-a-secret

Endpoints (token via ?token= or X-Auth-Token header):
    GET  /health          -> {ok, model_loaded, spotify_configured, ...}
    GET  /now-playing     -> current Spotify track, if configured
    POST /extract         -> {"url": "<spotify track url>"} -> {"job": id}
    GET  /status/<id>     -> job state machine
    GET  /audio/<id>      -> instrumental m4a
"""
import argparse
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

SERVER_DIR = Path(__file__).resolve().parent
REPO_ROOT = SERVER_DIR.parent
UVR_DIR = REPO_ROOT / "uvr"
WEIGHTS_PATH = UVR_DIR / "uvr5_weights" / "2_HP-UVR.pth"
WEIGHTS_URL = "https://huggingface.co/fastrolling/uvr/resolve/main/Main_Models/2_HP-UVR.pth"

TRACK_ID_RE = re.compile(
    r"(?:open\.spotify\.com/(?:[a-z-]+/)?track/|spotify:track:)([A-Za-z0-9]+)"
)

# ---------------------------------------------------------------------------
# Job store


class Job:
    def __init__(self, job_id, url):
        self.id = job_id
        self.url = url
        self.stage = "queued"  # queued|fetching|downloading|separating|encoding|done|error
        self.error = None
        self.title = None
        self.artist = None
        self.duration = None  # seconds
        self.artwork = None
        self.started = time.time()
        self.updated = time.time()

    def to_dict(self):
        return {
            "job": self.id,
            "url": self.url,
            "stage": self.stage,
            "error": self.error,
            "title": self.title,
            "artist": self.artist,
            "duration": self.duration,
            "artwork": self.artwork,
            "elapsed": round(time.time() - self.started, 1),
        }


JOBS = {}
JOBS_LOCK = threading.Lock()
WORK_QUEUE = queue.Queue()

# ---------------------------------------------------------------------------
# UVR model (loaded lazily, once)

_model_lock = threading.Lock()
_pre_fun = None
_device = "cpu"


def ensure_weights(log):
    if WEIGHTS_PATH.exists() and WEIGHTS_PATH.stat().st_size > 10_000_000:
        return
    WEIGHTS_PATH.parent.mkdir(parents=True, exist_ok=True)
    log(f"Downloading UVR model weights (~120 MB) to {WEIGHTS_PATH} ...")
    tmp = WEIGHTS_PATH.with_suffix(".pth.part")
    urllib.request.urlretrieve(WEIGHTS_URL, tmp)
    tmp.replace(WEIGHTS_PATH)
    log("Model weights downloaded.")


def get_model(log):
    global _pre_fun
    with _model_lock:
        if _pre_fun is None:
            ensure_weights(log)
            log(f"Loading UVR model on {_device} ...")
            from separate import _audio_pre_  # uvr/separate.py (on sys.path)

            _pre_fun = _audio_pre_(
                model_path=str(WEIGHTS_PATH),
                device=_device,
                is_half=(_device == "cuda"),
            )
            log("UVR model ready.")
        return _pre_fun


# ---------------------------------------------------------------------------
# Pipeline


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def run_spotdl(args_list, cwd, timeout=900):
    cmd = [sys.executable, "-m", "spotdl"] + args_list
    proc = subprocess.run(
        cmd, cwd=str(cwd), capture_output=True, text=True, timeout=timeout
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"spotdl failed ({proc.returncode}): {proc.stderr[-800:] or proc.stdout[-800:]}"
        )
    return proc.stdout


def process_job(job, work_dir):
    job_dir = work_dir / job.id
    job_dir.mkdir(parents=True, exist_ok=True)
    final = job_dir / "instrumental.m4a"
    canonical = f"https://open.spotify.com/track/{job.id}"

    # 1. Metadata (fast; fills in the card on the phone).
    job.stage = "fetching"
    job.updated = time.time()
    meta_file = job_dir / "meta.spotdl"
    try:
        if not meta_file.exists():
            run_spotdl(["save", canonical, "--save-file", str(meta_file)], job_dir, timeout=180)
        songs = json.loads(meta_file.read_text(encoding="utf-8"))
        if songs:
            s = songs[0]
            job.title = s.get("name")
            job.artist = ", ".join(s.get("artists") or []) or s.get("artist")
            job.duration = s.get("duration")
            job.artwork = s.get("cover_url")
    except Exception as e:  # metadata is best-effort
        log(f"[{job.id}] metadata fetch failed: {e}")

    if final.exists():
        job.stage = "done"
        job.updated = time.time()
        log(f"[{job.id}] cached result reused")
        return

    # 2. Download the full track.
    job.stage = "downloading"
    job.updated = time.time()
    track = next(job_dir.glob("track.*"), None)
    if track is None:
        run_spotdl(
            [
                "download",
                canonical,
                "--output",
                str(job_dir / "track.{output-ext}"),
                "--format",
                "mp3",
            ],
            job_dir,
        )
        track = next(job_dir.glob("track.*"), None)
    if track is None:
        raise RuntimeError("spotdl reported success but no audio file was written")
    log(f"[{job.id}] downloaded {track.name}")

    # 3. Isolate the instrumental with UVR.
    job.stage = "separating"
    job.updated = time.time()
    pre_fun = get_model(log)
    t0 = time.time()
    pre_fun._path_audio_(str(track), ins_root=str(job_dir), vocal_root=None)
    log(f"[{job.id}] separation took {time.time() - t0:.0f}s")
    ins_wav = job_dir / f"instrument_{track.name}.wav"
    if not ins_wav.exists():
        raise RuntimeError(f"UVR did not produce {ins_wav.name}")

    # 4. Encode to m4a for the phone.
    job.stage = "encoding"
    job.updated = time.time()
    proc = subprocess.run(
        [
            "ffmpeg", "-y", "-i", str(ins_wav),
            "-c:a", "aac", "-b:a", "192k", str(final),
        ],
        capture_output=True, text=True, timeout=300,
    )
    if proc.returncode != 0 or not final.exists():
        raise RuntimeError(f"ffmpeg encode failed: {proc.stderr[-500:]}")
    ins_wav.unlink(missing_ok=True)

    job.stage = "done"
    job.updated = time.time()
    log(f"[{job.id}] done -> {final}")


def worker(work_dir):
    while True:
        job = WORK_QUEUE.get()
        try:
            process_job(job, work_dir)
        except Exception as e:
            job.stage = "error"
            job.error = str(e)
            job.updated = time.time()
            log(f"[{job.id}] ERROR: {e}")


# ---------------------------------------------------------------------------
# Spotify now-playing (optional)

_spotify = None


def init_spotify():
    global _spotify
    if not (os.environ.get("SPOTIPY_CLIENT_ID") and os.environ.get("SPOTIPY_CLIENT_SECRET")):
        return False
    try:
        import spotipy
        from spotipy.oauth2 import SpotifyOAuth
    except ImportError:
        log("spotipy not installed; /now-playing disabled")
        return False
    auth = SpotifyOAuth(
        scope="user-read-currently-playing user-read-playback-state",
        redirect_uri=os.environ.get("SPOTIPY_REDIRECT_URI", "http://127.0.0.1:8899/callback"),
        cache_path=str(SERVER_DIR / ".spotify-cache"),
        open_browser=True,
    )
    _spotify = spotipy.Spotify(auth_manager=auth)
    # Force the OAuth dance now (opens a browser on this machine once).
    me = _spotify.current_user()
    log(f"Spotify connected as {me.get('display_name') or me.get('id')}")
    return True


def now_playing():
    if _spotify is None:
        return None, "Spotify not configured on the server"
    try:
        cur = _spotify.current_user_playing_track()
    except Exception as e:
        return None, f"Spotify API error: {e}"
    if not cur or not cur.get("item"):
        return {"playing": False}, None
    item = cur["item"]
    images = (item.get("album") or {}).get("images") or []
    return {
        "playing": bool(cur.get("is_playing")),
        "title": item.get("name"),
        "artist": ", ".join(a["name"] for a in item.get("artists", [])),
        "url": (item.get("external_urls") or {}).get("spotify"),
        "artwork": images[0]["url"] if images else None,
        "duration": (item.get("duration_ms") or 0) // 1000,
    }, None


# ---------------------------------------------------------------------------
# HTTP


class Handler(BaseHTTPRequestHandler):
    server_version = "Backtrack/1.0"
    token = ""
    work_dir = None

    def log_message(self, fmt, *args):
        log(f"{self.address_string()} {fmt % args}")

    def _send_json(self, obj, code=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self, query):
        if not self.token:
            return True
        supplied = self.headers.get("X-Auth-Token") or (query.get("token") or [""])[0]
        return supplied == self.token

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        path = parsed.path.rstrip("/") or "/"

        if path == "/health":
            self._send_json({
                "ok": True,
                "model_loaded": _pre_fun is not None,
                "device": _device,
                "spotify_configured": _spotify is not None,
                "auth_required": bool(self.token),
            })
            return

        if not self._authorized(query):
            self._send_json({"error": "unauthorized"}, 401)
            return

        if path == "/now-playing":
            data, err = now_playing()
            if err:
                self._send_json({"error": err}, 503)
            else:
                self._send_json(data)
            return

        m = re.fullmatch(r"/status/([A-Za-z0-9]+)", path)
        if m:
            with JOBS_LOCK:
                job = JOBS.get(m.group(1))
            if job is None:
                self._send_json({"error": "unknown job"}, 404)
            else:
                self._send_json(job.to_dict())
            return

        m = re.fullmatch(r"/audio/([A-Za-z0-9]+)", path)
        if m:
            f = self.work_dir / m.group(1) / "instrumental.m4a"
            if not f.exists():
                self._send_json({"error": "not ready"}, 404)
                return
            size = f.stat().st_size
            self.send_response(200)
            self.send_header("Content-Type", "audio/mp4")
            self.send_header("Content-Length", str(size))
            self.end_headers()
            with open(f, "rb") as fh:
                shutil.copyfileobj(fh, self.wfile)
            return

        self._send_json({"error": "not found"}, 404)

    def do_POST(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if not self._authorized(query):
            self._send_json({"error": "unauthorized"}, 401)
            return
        if parsed.path.rstrip("/") != "/extract":
            self._send_json({"error": "not found"}, 404)
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self._send_json({"error": "bad JSON body"}, 400)
            return
        url = (payload.get("url") or "").strip()
        m = TRACK_ID_RE.search(url)
        if not m:
            self._send_json(
                {"error": "not a Spotify track link (need open.spotify.com/track/...)"},
                400,
            )
            return
        track_id = m.group(1)
        with JOBS_LOCK:
            job = JOBS.get(track_id)
            if job is None or job.stage == "error":
                job = Job(track_id, url)
                JOBS[track_id] = job
                WORK_QUEUE.put(job)
        self._send_json(job.to_dict())


def main():
    global _device
    ap = argparse.ArgumentParser(description="Backtrack desktop server")
    ap.add_argument("--port", type=int, default=8790)
    ap.add_argument("--token", default="", help="shared secret; empty disables auth")
    ap.add_argument("--device", default="auto", choices=["auto", "cpu", "cuda"])
    ap.add_argument("--work-dir", default=str(SERVER_DIR / "work"))
    args = ap.parse_args()

    import torch

    if args.device == "auto":
        _device = "cuda" if torch.cuda.is_available() else "cpu"
    else:
        _device = args.device

    # UVR resolves modelparams/*.json relative to the CWD, so live in uvr/.
    sys.path.insert(0, str(UVR_DIR))
    os.chdir(UVR_DIR)

    work_dir = Path(args.work_dir).resolve()
    work_dir.mkdir(parents=True, exist_ok=True)

    Handler.token = args.token
    Handler.work_dir = work_dir

    if init_spotify():
        pass
    else:
        log("Now-playing disabled (set SPOTIPY_CLIENT_ID / SPOTIPY_CLIENT_SECRET to enable).")

    threading.Thread(target=worker, args=(work_dir,), daemon=True).start()

    # Warm the model in the background so the first job doesn't pay for it.
    threading.Thread(target=lambda: get_model(log), daemon=True).start()

    httpd = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    log(f"Backtrack server on 0.0.0.0:{args.port} (device={_device}, "
        f"auth={'on' if args.token else 'OFF'})")
    log("Connect the app to this machine's Tailscale IP, e.g. http://100.x.y.z:%d" % args.port)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
