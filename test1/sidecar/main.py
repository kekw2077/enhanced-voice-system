"""EVS sidecar — local voice/ML brain for the EVS desktop app.

A WebSocket server on 127.0.0.1 that exposes STT (faster-whisper), VAD
(webrtcvad), TTS (pyttsx3) and fuzzy command intent matching. The Flutter app
launches this process, reads the chosen port from the "EVS_SIDECAR_READY <port>"
stdout line, then connects.

Protocol (JSON text frames)
  client -> server:
    {"type": "stt.start", "language": "ru"|"en"|"auto"}
    {"type": "stt.stop"}
    {"type": "tts.speak", "text": "..."}
    {"type": "tts.stop"}
    {"type": "intent.parse", "text": "...", "commands": [{"phrase": "..."}], "threshold": 0.5}
    {"type": "ping"}
  server -> client:
    {"type": "ready", "capabilities": {"stt": bool, "tts": bool}}
    {"type": "vad", "speaking": bool}
    {"type": "stt.partial", "text": "..."}
    {"type": "stt.final", "text": "..."}
    {"type": "tts.done"}
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
from stt_engine import SttEngine
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
    await ws.send(json.dumps({
        "type": "ready",
        "capabilities": {"stt": stt.available, "tts": tts.available},
    }))

    try:
        async for raw in ws:
            try:
                data = json.loads(raw)
            except Exception:
                continue
            t = data.get("type")
            if t == "stt.start":
                stt.start(data.get("language", "ru"), emit)
            elif t == "stt.stop":
                stt.stop()
            elif t == "stt.config":
                model = data.get("model")
                if model:
                    stt.set_model(str(model))
            elif t == "tts.speak":
                tts.speak(str(data.get("text", "")),
                          rate=float(data.get("rate", 1.0)),
                          volume=float(data.get("volume", 1.0)),
                          on_done=lambda: emit({"type": "tts.done"}),
                          on_level=lambda v: emit(
                              {"type": "tts.level", "level": v}))
            elif t == "tts.stop":
                tts.stop()
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
    stt = SttEngine(args.model, args.device, args.compute_type)
    tts = TtsEngine()

    async def handler(ws):
        await _handle(ws, stt, tts)

    async with websockets.serve(handler, args.host, args.port) as server:
        port = args.port or server.sockets[0].getsockname()[1]
        # Flutter parses this line from stdout to learn the port.
        print(f"EVS_SIDECAR_READY {port}", flush=True)
        await asyncio.Future()  # run forever


def main() -> None:
    ap = argparse.ArgumentParser(description="EVS voice/ML sidecar")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=0, help="0 = pick a free port")
    ap.add_argument("--model", default="small", help="faster-whisper model size")
    ap.add_argument("--device", default="cpu", help="cpu | cuda")
    ap.add_argument("--compute-type", dest="compute_type", default="int8")
    args = ap.parse_args()
    try:
        asyncio.run(_main(args))
    except KeyboardInterrupt:
        pass
    except Exception as e:  # pragma: no cover
        print(f"EVS_SIDECAR_ERROR {e}", file=sys.stderr, flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
