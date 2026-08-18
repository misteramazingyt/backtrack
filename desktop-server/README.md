# Backtrack desktop server

Does the work the phone can't: spotdl download -> UVR instrumental isolation ->
ffmpeg m4a encode, served over the tailnet to the Backtrack iOS app.

## Setup (once)

Requirements: Python 3.11 (`py -3.11`), ffmpeg on PATH. setup.ps1 also
installs [deno](https://deno.land) if missing - yt-dlp needs a JS runtime for
YouTube downloads (without one they 403).

```powershell
powershell -File setup.ps1
```

This creates `.venv` (pinned to the librosa-0.9-era stack the vendored UVR
code needs) and downloads the `2_HP-UVR.pth` model weights (~120 MB).

## Run

```powershell
.venv\Scripts\python server.py --port 8790 --token pick-a-secret
```

Flags: `--device auto|cpu|cuda` (auto picks CUDA when available),
`--work-dir` (default `work/`, one cached folder per track).

## Spotify "currently playing" (optional)

Create a free app at https://developer.spotify.com/dashboard, add redirect URI
`http://127.0.0.1:8899/callback`, then:

```powershell
$env:SPOTIPY_CLIENT_ID = "..."
$env:SPOTIPY_CLIENT_SECRET = "..."
.venv\Scripts\python server.py --port 8790 --token pick-a-secret
```

First launch opens a browser to authorize; the token caches in
`.spotify-cache`. Without these env vars the server still works - the app
just won't show the now-playing card.

## API

| Route | Method | Purpose |
| --- | --- | --- |
| `/health` | GET | liveness + config info (no auth) |
| `/now-playing` | GET | current Spotify track |
| `/extract` | POST `{"url": ...}` | start/reuse a job for a track link |
| `/status/<id>` | GET | job stage: `fetching -> downloading -> separating -> encoding -> done` |
| `/audio/<id>` | GET | the finished instrumental (audio/mp4) |

Auth: send the token as `X-Auth-Token` header or `?token=` query param.

## Autostart (optional)

```powershell
schtasks /create /tn BacktrackServer /sc onlogon /tr "powershell -WindowStyle Hidden -Command \"cd 'D:\path\to\repo\desktop-server'; $env:SPOTIPY_CLIENT_ID='...'; $env:SPOTIPY_CLIENT_SECRET='...'; .venv\Scripts\python server.py --port 8790 --token pick-a-secret\""
```
