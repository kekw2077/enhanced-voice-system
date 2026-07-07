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
                           "denoise": "off"|"light"|"strong", "denoise_dir": "..."}
    {"type": "tts.speak", "text": "..."}
    {"type": "tts.stop"}
    {"type": "tts.config", "engine": "piper"|"pyttsx3",
                           "voice": "ru_RU-irina-medium", "voice_dir": "..."}
    {"type": "intent.parse", "text": "...", "commands": [{"phrase": "..."}], "threshold": 0.5}
    {"type": "ping"}
  server -> client:
    {"type": "ready", "capabilities": {"stt": bool, "tts": bool,
                                       "engines": {"whisper": bool, "gigaam": bool}}}
    {"type": "vad", "speaking": bool}
    {"type": "stt.partial", "text": "..."}
    {"type": "stt.final", "text": "...", "latency_ms": int}
    {"type": "stt.state", "state": "starting"|"loading_models"|"ready"|"error", "message"?: str}
    {"type": "stt.engine_status", "engine": str, "state": "loading"|"ready"|"error", "message"?: str}
    {"type": "stt.denoise_status", "mode": str, "state": "ready"|"error", "message"?: str}
    {"type": "tts.done"}
    {"type": "tts.status", "engine": str, "voice": str, "state": "loading"|"ready"|"error", "message"?: str}
    {"type": "intent.result", "match": {...}|null}
    {"type": "pong"}
    {"type": "error", "message": "..."}
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys

import websockets

from intent import match
from stt_engine import SttEngine, log_stage
from tts_engine import TtsEngine


async def _handle(ws, stt: SttEngine, tts: TtsEngine) -> None:
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
        },
    }))
    # Bind this connection's emitter so engine-status can be reported outside of
    # start/stop, and apply the CLI/desired engines (reports their readiness).
    stt.bind(emit)
    tts.bind(emit)

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
                          prompt=data.get("prompt"))
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
            elif t == "intent.parse":
                res = match(
                    str(data.get("text", "")),
                    list(data.get("commands", [])),
                    float(data.get("threshold", 0.5)),
                )
                emit({"type": "intent.result", "match": res})
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

    async def handler(ws):
        await _handle(ws, stt, tts)

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
