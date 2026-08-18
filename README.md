# Backtrack

Extract and play the instrumental from any Spotify track.

Paste a Spotify link (or use whatever is currently playing on Spotify), tap
**Isolate Background Music**, and play the vocal-free result — right on your
phone.

Two pieces, one repo:

- **`Backtrack/`** — the iOS app (SwiftUI, iOS 17+). Pure UI + playback.
- **`desktop-server/`** — a small Python server that runs on your computer and
  does the heavy lifting: [spotdl](https://github.com/spotDL/spotify-downloader)
  downloads the track, the vendored [`uvr/`](uvr/) (Ultimate Vocal Remover CLI)
  isolates the instrumental, ffmpeg encodes it to m4a for the phone. The phone
  talks to it over Tailscale.

## Desktop server

One-time setup (Windows; needs Python 3.11 and ffmpeg on PATH):

```powershell
cd desktop-server
powershell -File setup.ps1
```

Run it:

```powershell
.venv\Scripts\python server.py --port 8787 --token pick-a-secret
```

Optional — enable the "currently playing on Spotify" card: create a (free)
app at https://developer.spotify.com/dashboard with redirect URI
`http://127.0.0.1:8899/callback`, then before starting the server:

```powershell
$env:SPOTIPY_CLIENT_ID = "your-client-id"
$env:SPOTIPY_CLIENT_SECRET = "your-client-secret"
```

A browser opens once to authorize; the token is cached in
`desktop-server/.spotify-cache`.

In the app's Settings (gear icon), enter `http://<tailscale-ip>:8787` and the
token. Plain HTTP is fine on the tailnet — Tailscale encrypts it end to end
(that's what the ATS exception in the app is for).

## Building the app

CI (GitHub Actions) is the normal path: every push to `main` builds an
**unsigned** device IPA on a macOS runner and uploads it as the
`Backtrack-unsigned-ipa` artifact. Download it from the run's Artifacts
section (or `gh run download <run-id>`), then sign + install with your usual
sideloading tool (Sideloadly, AltStore) under a free personal Apple ID.
Free-provisioning installs expire after 7 days — just re-sign.

Locally on a Mac instead:

```sh
brew install xcodegen
xcodegen generate
open Backtrack.xcodeproj   # set your Team in Signing & Capabilities, then Cmd-R
```

The `.xcodeproj` is generated from [project.yml](project.yml) and stays out of
version control.

## How a request flows

1. App POSTs the track URL to `/extract`; the server queues a job keyed by the
   Spotify track ID (repeat requests hit the cache).
2. `spotdl save` fetches title/artist/artwork (fast, fills in the card), then
   `spotdl download` grabs the audio as mp3.
3. UVR's `2_HP-UVR` model (auto-downloaded to `uvr/uvr5_weights/` on first
   run, ~120 MB) separates the instrumental — on GPU if available, otherwise
   CPU (expect a couple of minutes per song on CPU).
4. ffmpeg encodes the instrumental to m4a; the app polls `/status/<id>`,
   downloads `/audio/<id>`, renders the waveform, and plays it.
