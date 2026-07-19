"""EVS sidecar — local voice/ML brain for the EVS desktop app.

A WebSocket server on 127.0.0.1 that exposes STT (faster-whisper), VAD
(webrtcvad), TTS (pyttsx3) and fuzzy command intent matching. The Flutter app
launches this process, reads the chosen port from the "EVS_SIDECAR_READY <port>"
stdout line, then connects.

Protocol (JSON text frames)
  client -> server:
    {"type": "stt.start", "language": "ru"|"en"|"auto"}
    {"type": "stt.stop"}
    {"type": "stt.config", "model": "small", "prompt": "...",
                           "engine": "whisper"|"gigaam", "gigaam_dir": "...",
                           "denoise": "off"|"light"|"strong", "denoise_dir": "...",
                           "device": "cpu"|"cuda"}
    {"type": "gamemode.config", "fullscreen_enabled": bool, "vram_enabled": bool,
                           "vram_enter": 85, "vram_exit": 65, "notify_enabled": bool,
                           "exclusions": ["vlc.exe"], "texts": {"fullscreen": ..., "vram": ..., "exit": ...}}
    {"type": "tts.speak", "text": "..."}
    {"type": "tts.stop"}
    {"type": "tts.config", "engine": "piper"|"pyttsx3",
                           "voice": "ru_RU-irina-medium", "voice_dir": "..."}
    {"type": "tts.preview", "voice": "...", "voice_dir": "...", "text": "..."}
    {"type": "intent.parse", "text": "...", "commands": [{"phrase": "..."}], "threshold": 0.5}
    {"type": "audio.sessions"}                       # list active per-app audio sessions
    {"type": "app.volume", "process": "Yandex Music.exe",
                           "action": "set"|"increase"|"decrease"|"mute"|"unmute",
                           "value": 0.30}             # 0..1 for set/increase/decrease
    {"type": "stt.transcribe", "id": str, "audio": "<base64>",
                               "format": "wav"|"pcm16"}  # one-shot network voice cmd
    {"type": "ping"}
  server -> client:
    {"type": "ready", "capabilities": {"stt": bool, "tts": bool,
                                       "engines": {"whisper": bool, "gigaam": bool}}}
    {"type": "vad", "speaking": bool}
    {"type": "stt.partial", "text": "..."}
    {"type": "stt.final", "text": "...", "latency_ms": int}
    {"type": "stt.state", "state": "starting"|"loading_models"|"ready"|"error", "message"?: str}
    {"type": "stt.engine_status", "engine": str, "state": "loading"|"ready"|"error", "message"?: str}
    {"type": "stt.device", "engine": str, "requested": "cpu"|"cuda", "active": "cpu"|"cuda", "fell_back": bool}
    {"type": "gamemode.status", "active": bool, "reason": "fullscreen"|"vram"|""}
    {"type": "stt.denoise_status", "mode": str, "state": "ready"|"error", "message"?: str}
    {"type": "tts.done"}
    {"type": "tts.status", "engine": str, "voice": str, "state": "loading"|"ready"|"error", "message"?: str}
    {"type": "intent.result", "match": {...}|null}
    {"type": "audio.sessions.result",
        "sessions": [{"process": str, "display_name": str, "volume": float|null}]}
    {"type": "app.volume.result",
        "ok": bool, "found": int, "volume": float|null, "process": str, "action": str}
    {"type": "stt.transcribe.result", "id": str, "text": str, "error"?: str}
    {"type": "pong"}
    {"type": "error", "message": "..."}
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import io
import json
import sys
import wave

import websockets

import gpu
from gamemode import GameModeMonitor
from intent import match
from stt_engine import SAMPLE_RATE, SttEngine, log_stage
from tts_engine import TtsEngine


def _decode_to_pcm16k_mono(np, raw: bytes, fmt: str = "wav") -> bytes:
    """Normalize incoming command audio to the STT engines' native format:
    16 kHz, mono, signed 16-bit little-endian PCM.

    Accepts a full WAV container (any sample rate / channel count / bit depth)
    or, when `fmt` is "pcm16", already-raw 16 kHz mono int16. Downmix and
    resampling use numpy only (linear interpolation) — no extra dependency and
    no audioop, which is gone in Python 3.13+. Raises on unparseable input so
    the caller can report an error rather than feed the engine garbage."""
    if fmt == "pcm16":
        return raw

    with wave.open(io.BytesIO(raw), "rb") as w:
        channels = w.getnchannels()
        width = w.getsampwidth()
        rate = w.getframerate()
        frames = w.readframes(w.getnframes())

    if width == 1:  # 8-bit WAV is unsigned; center it before scaling to int16
        samples = (np.frombuffer(frames, dtype=np.uint8).astype(np.float32) - 128.0) \
            * 256.0
    elif width == 2:
        samples = np.frombuffer(frames, dtype=np.int16).astype(np.float32)
    elif width == 4:
        samples = np.frombuffer(frames, dtype=np.int32).astype(np.float32) / 65536.0
    else:
        raise ValueError(f"unsupported WAV sample width: {width}")

    if channels > 1:  # average channels down to mono
        samples = samples.reshape(-1, channels).mean(axis=1)

    if rate != SAMPLE_RATE and samples.size:  # linear resample to 16 kHz
        duration = samples.size / float(rate)
        n_out = max(1, int(round(duration * SAMPLE_RATE)))
        src_idx = np.linspace(0.0, samples.size - 1, num=n_out)
        samples = np.interp(src_idx, np.arange(samples.size), samples)

    return np.clip(samples, -32768.0, 32767.0).astype("<i2").tobytes()


async def _handle(ws, stt: SttEngine, tts: TtsEngine,
                  game: GameModeMonitor) -> None:
    loop = asyncio.get_running_loop()
    out: "asyncio.Queue[dict]" = asyncio.Queue()

    def emit(msg: dict) -> None:
        # Called from worker threads (STT/TTS) — hop back onto the loop.
        loop.call_soon_threadsafe(out.put_nowait, msg)

    async def sender() -> None:
        while True:
            msg = await out.get()
            await ws.send(json.dumps(msg, ensure_ascii=False))

    send_task = asyncio.create_task(sender())
    log_stage("flutter connected")
    await ws.send(json.dumps({
        "type": "ready",
        "capabilities": {
            "stt": stt.available,
            "tts": tts.available,
            "engines": stt.capabilities(),
            "tts_engines": tts.capabilities(),
            "gpu": gpu.gpu_info(),
        },
    }))
    # Bind this connection's emitter so engine-status can be reported outside of
    # start/stop, and apply the CLI/desired engines (reports their readiness).
    stt.bind(emit)
    tts.bind(emit)

    # Game mode (TZ2 block 7): one offload layer driven by both triggers.
    def _game_change(active: bool, reason: str) -> None:
        stt.force_cpu(active)  # only Whisper has a CUDA path here
        emit({"type": "gamemode.status", "active": active, "reason": reason})

    def _game_notify(kind: str) -> None:
        txt = game.texts.get(kind)
        if txt:
            tts.speak(str(txt))

    game.bind(_game_change, _game_notify)
    game.start()

    try:
        async for raw in ws:
            try:
                data = json.loads(raw)
            except Exception:
                continue
            t = data.get("type")
            if t == "stt.start":
                stt.start(data.get("language", "ru"), emit,
                          device=data.get("device"),
                          prompt=data.get("prompt"),
                          devices=data.get("devices"))
            elif t == "stt.stop":
                stt.stop()
            elif t == "stt.config":
                model = data.get("model")
                if model:
                    stt.set_model(str(model))
                if "prompt" in data:
                    stt.set_prompt(data.get("prompt"))
                gdir = data.get("gigaam_dir")
                if gdir:
                    stt.update_gigaam_dir(str(gdir))
                engine = data.get("engine")
                if engine:
                    stt.set_engine(str(engine), str(gdir) if gdir else None)
                ddir = data.get("denoise_dir")
                if ddir:
                    stt.update_denoise_dir(str(ddir))
                if "denoise" in data:
                    stt.set_denoise(str(data.get("denoise")))
                if "device" in data:
                    # A manual device change lifts any game-mode offload layer
                    # (it re-engages next poll if conditions still hold).
                    game.release()
                    stt.set_device(str(data.get("device")))
                if "vad" in data:
                    stt.set_vad_aggressiveness(data.get("vad"))
            elif t == "tts.speak":
                tts.speak(str(data.get("text", "")),
                          rate=float(data.get("rate", 1.0)),
                          volume=float(data.get("volume", 1.0)),
                          on_done=lambda: emit({"type": "tts.done"}),
                          on_level=lambda v: emit(
                              {"type": "tts.level", "level": v}))
            elif t == "tts.stop":
                tts.stop()
            elif t == "tts.config":
                vdir = data.get("voice_dir")
                voice = data.get("voice")
                if vdir is not None or voice is not None:
                    tts.set_voice(str(vdir) if vdir else "",
                                  str(voice) if voice else "")
                eng = data.get("engine")
                if eng:
                    tts.set_engine(str(eng))
            elif t == "tts.preview":
                tts.preview(str(data.get("voice_dir", "")),
                            str(data.get("voice", "")),
                            str(data.get("text", "")),
                            rate=float(data.get("rate", 1.0)),
                            volume=float(data.get("volume", 1.0)))
            elif t == "gamemode.config":
                if isinstance(data.get("texts"), dict):
                    game.texts = {str(k): str(v)
                                  for k, v in data["texts"].items()}
                game.configure(
                    fullscreen_enabled=data.get("fullscreen_enabled"),
                    vram_enabled=data.get("vram_enabled"),
                    vram_enter=data.get("vram_enter"),
                    vram_exit=data.get("vram_exit"),
                    notify_enabled=data.get("notify_enabled"),
                    exclusions=data.get("exclusions"),
                )
            elif t == "intent.parse":
                res = match(
                    str(data.get("text", "")),
                    list(data.get("commands", [])),
                    float(data.get("threshold", 0.5)),
                )
                emit({"type": "intent.result", "match": res})
            elif t == "audio.sessions":
                # COM/pycaw is blocking — run it off the event loop.
                import app_audio
                sess = await asyncio.get_event_loop().run_in_executor(
                    None, app_audio.list_sessions)
                emit({"type": "audio.sessions.result", "sessions": sess})
            elif t == "app.volume":
                import app_audio
                _v = data.get("value")
                _proc = str(data.get("process", ""))
                _act = str(data.get("action", "set"))
                r = await asyncio.get_event_loop().run_in_executor(
                    None,
                    lambda: app_audio.apply(
                        _proc, _act,
                        float(_v) if _v is not None else None))
                emit({"type": "app.volume.result", **r})
            elif t == "stt.transcribe":
                # One-shot offline recognition for a network voice command
                # (settings-TZ §14). `audio` is base64; `format` is "wav"
                # (default) or "pcm16" (raw 16 kHz mono int16). Decode +
                # recognize off the event loop; reply is keyed by `id` so the
                # Dart side can match it even if several arrive at once.
                rid = data.get("id")
                b64 = str(data.get("audio", ""))
                fmt = str(data.get("format", "wav"))

                def _run_transcribe(b64=b64, fmt=fmt):
                    import numpy as np
                    pcm = _decode_to_pcm16k_mono(np, base64.b64decode(b64), fmt)
                    return stt.transcribe_pcm(np, pcm)

                try:
                    text = await asyncio.get_event_loop().run_in_executor(
                        None, _run_transcribe)
                    emit({"type": "stt.transcribe.result",
                          "id": rid, "text": text})
                except Exception as e:  # bad audio / decode failure
                    emit({"type": "stt.transcribe.result",
                          "id": rid, "text": "", "error": str(e)})
            elif t == "ping":
                emit({"type": "pong"})
    except websockets.ConnectionClosed:
        pass
    finally:
        send_task.cancel()
        stt.stop()


async def _main(args) -> None:
    stt = SttEngine(args.model, args.device, args.compute_type,
                    engine=args.engine, gigaam_dir=args.gigaam_dir,
                    denoise=args.denoise, denoise_dir=args.denoise_dir)
    tts = TtsEngine(engine=args.tts_engine, voice=args.tts_voice,
                    voice_dir=args.tts_voice_dir)
    game = GameModeMonitor()

    async def handler(ws):
        await _handle(ws, stt, tts, game)

    log_stage("intent matcher ready; ws server starting")
    async with websockets.serve(handler, args.host, args.port) as server:
        port = args.port or server.sockets[0].getsockname()[1]
        # Flutter parses this line from stdout to learn the port.
        print(f"EVS_SIDECAR_READY {port}", flush=True)
        log_stage(f"ws server listening on port {port}")
        # Start the parent-death watcher ONLY now — after the heavy engine
        # imports (sounddevice/faster-whisper) and the READY print. Its blocking
        # `sys.stdin.buffer.read()` holds the stdin BufferedReader lock, and if
        # it runs during those imports it can deadlock startup so READY never
        # prints (observed: sidecar "Не запущен", process alive but no socket).
        _watch_parent()
        await asyncio.Future()  # run forever


def _watch_parent() -> None:
    """Exit when the launching app dies.

    The app holds our stdin pipe; if it crashes or is force-killed, stdin
    hits EOF — without this watcher, orphaned sidecars pile up (observed: 5
    evs_sidecar.exe processes after repeated app kills).
    """
    import os
    import threading

    def _watch() -> None:
        try:
            while sys.stdin.buffer.read(4096):
                pass
        except Exception:
            pass
        os._exit(0)

    threading.Thread(target=_watch, daemon=True).start()


def main() -> None:
    ap = argparse.ArgumentParser(description="EVS voice/ML sidecar")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=0, help="0 = pick a free port")
    ap.add_argument("--model", default="small", help="faster-whisper model size")
    ap.add_argument("--device", default="cpu", help="cpu | cuda")
    ap.add_argument("--compute-type", dest="compute_type", default="int8")
    ap.add_argument("--engine", default="whisper", help="whisper | gigaam")
    ap.add_argument("--gigaam-dir", dest="gigaam_dir", default="",
                    help="GigaAM sherpa-onnx model directory")
    ap.add_argument("--denoise", default="off", help="off | light | strong")
    ap.add_argument("--denoise-dir", dest="denoise_dir", default="",
                    help="models root holding denoise-gtcrn/ and denoise-df/")
    ap.add_argument("--tts-engine", dest="tts_engine", default="piper",
                    help="piper (default) | pyttsx3")
    ap.add_argument("--tts-voice", dest="tts_voice", default="",
                    help="Piper voice id, e.g. ru_RU-irina-medium")
    ap.add_argument("--tts-voice-dir", dest="tts_voice_dir", default="",
                    help="dir holding the Piper voice bundle (<userdata>/models/<id>)")
    args = ap.parse_args()
    # NOTE: _watch_parent() is started from inside _main(), AFTER the server is
    # up and READY is printed — starting it here (before the heavy imports)
    # deadlocked startup on some Windows setups (stdin BufferedReader lock).
    try:
        asyncio.run(_main(args))
    except KeyboardInterrupt:
        pass
    except Exception as e:  # pragma: no cover
        print(f"EVS_SIDECAR_ERROR {e}", file=sys.stderr, flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
