# EVS XTTS voice-clone sidecar (`evs_tts.exe` component)

Separate, on-demand process (Coqui **XTTS v2**) that synthesizes speech in the
user's **cloned voice** from a short reference WAV. Kept apart from the base
sidecar because torch + the XTTS model are huge — it's the `tts-clone`
component, downloaded on demand (not bundled in the installer).

## Protocol (localhost WebSocket)

Prints `EVS_TTS_READY <port>` on stdout, then speaks JSON frames — see
`main.py`. Key messages: `tts.load`, `tts.clone {speaker_wav}`,
`tts.speak {text, language, speaker_wav}`, `tts.stop`, `ping`.

The engine plays audio itself (sounddevice), so Flutter just sends text.

## Dev

```powershell
uv venv --python 3.12 .venv
$env:VIRTUAL_ENV = (Resolve-Path .venv).Path
uv pip install -r requirements.txt
# Coqui needs license consent + a model cache dir:
$env:COQUI_TOS_AGREED = "1"
$env:TTS_HOME = "$env:APPDATA\com.example\EVS\components\tts-cache"
.\.venv\Scripts\python.exe main.py --port 0
```

In a dev build the Flutter app finds `sidecar/tts_xtts/main.py` + this venv.

## Notes / gotchas

- **torch isn't pulled transitively** by coqui-tts on Windows — it's required
  explicitly in `requirements.txt`.
- **transformers must be 4.x** — XTTS breaks on transformers 5.x.
- The XTTS model (~1.8 GB) downloads on first `tts.load` into `TTS_HOME`
  (the app data folder). `COQUI_TOS_AGREED=1` auto-accepts the model license
  (CPML, non-commercial) so the process doesn't block on a prompt.
- CPU synthesis is slow (a few seconds per sentence); GPU is much faster.

## Freeze + publish

```powershell
.\build_exe.ps1 -ComponentVersion 1      # -> dist\evs_tts.exe + components.json
gh release upload desktop-components dist\evs_tts.exe --clobber
# then commit ../../dist/components.json on the desktop branch
```
