# Creates the Python 3.11 venv the Backtrack server runs in and downloads
# the UVR model weights. Run once:  powershell -File setup.ps1
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

py -3.11 -m venv .venv
& .venv\Scripts\python -m pip install --upgrade pip
& .venv\Scripts\pip install -r requirements.txt

# Model weights (~120 MB); server also auto-downloads if missing.
$weights = Join-Path $PSScriptRoot "..\uvr\uvr5_weights\2_HP-UVR.pth"
if (-not (Test-Path $weights)) {
  Write-Host "Downloading UVR model weights..."
  Invoke-WebRequest -Uri "https://huggingface.co/fastrolling/uvr/resolve/main/Main_Models/2_HP-UVR.pth" -OutFile $weights
}

Write-Host ""
Write-Host "Done. Start the server with:"
Write-Host "  .venv\Scripts\python server.py --port 8790 --token pick-a-secret"
