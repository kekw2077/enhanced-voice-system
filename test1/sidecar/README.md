# EVS sidecar

Local voice/ML brain for the EVS desktop app: STT (faster-whisper), VAD
(webrtcvad), TTS (pyttsx3) and fuzzy command intent matching, exposed over a
localhost WebSocket. The Flutter app launches this process and connects.

## Dev setup (Windows)

```powershell
cd test1\sidecar
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python main.py --model small --device cpu
```

On start it prints `EVS_SIDECAR_READY <port>` to stdout — that's the WebSocket
port (`ws://127.0.0.1:<port>`). With `--port 0` (default) a free port is chosen.

The first STT request downloads the faster-whisper model (cached under
`%USERPROFILE%\.cache\huggingface`). Use `--model tiny|base|small|medium` to
trade quality for speed/size; `--device cuda` if a CUDA GPU is available.

## How Flutter uses it

In dev the app runs `python <this dir>\main.py` if no frozen exe is found; in a
release build it runs the bundled `evs_sidecar.exe` placed next to the app
executable. See `SidecarClient` in `lib/main.dart`.

## Packaging (release)

Freeze to a single self-contained exe with PyInstaller, then bundle it next to
`evs.exe`:

```powershell
.\.venv\Scripts\Activate.ps1
pip install pyinstaller
pyinstaller --onefile --name evs_sidecar main.py
# -> dist\evs_sidecar.exe
```

Note: faster-whisper/ctranslate2 are large; the resulting exe is a few hundred
MB. The model itself is downloaded on first run (not embedded) unless you ship
it alongside and point `--model` at a local path.

## Protocol

JSON text frames over WebSocket — see the module docstring in `main.py`.
