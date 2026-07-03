"""EVS XTTS sidecar — voice cloning over a localhost WebSocket.

A separate, on-demand process (downloaded as the `tts-clone` component) so the
heavy torch/XTTS deps don't bloat the base sidecar. The Flutter app launches it
when ttsVoice == 'cloned', reads "EVS_TTS_READY <port>" from stdout, connects.

Protocol (JSON text frames)
  client -> server:
    {"type": "tts.load"}
    {"type": "tts.clone", "speaker_wav": "C:/path/sample.wav"}
    {"type": "tts.speak", "text": "...", "language": "ru"|"en", "speaker_wav": "..."}
    {"type": "tts.stop"}
    {"type": "ping"}
  server -> client:
    {"type": "ready", "capabilities": {"tts": bool}}
    {"type": "tts.loaded", "ok": bool}
    {"type": "tts.cloned"}
    {"type": "tts.done"}
    {"type": "tts.error", "message": "..."}
    {"type": "pong"}
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys

import websockets

from xtts_engine import XttsEngine


async def _handle(ws, eng: XttsEngine) -> None:
    loop = asyncio.get_running_loop()
    out: "asyncio.Queue[dict]" = asyncio.Queue()

    def emit(msg: dict) -> None:
        loop.call_soon_threadsafe(out.put_nowait, msg)

    async def sender() -> None:
        while True:
            msg = await out.get()
            await ws.send(json.dumps(msg, ensure_ascii=False))

    send_task = asyncio.create_task(sender())
    await ws.send(json.dumps(
        {"type": "ready", "capabilities": {"tts": eng.available}}))

    try:
        async for raw in ws:
            try:
                data = json.loads(raw)
            except Exception:
                continue
            t = data.get("type")
            if t == "tts.load":
                ok = await loop.run_in_executor(None, eng.load)
                emit({"type": "tts.loaded", "ok": ok})
            elif t == "tts.clone":
                eng.set_speaker(str(data.get("speaker_wav", "")))
                emit({"type": "tts.cloned"})
            elif t == "tts.speak":
                sp = str(data.get("speaker_wav", "") or "")
                if sp:
                    eng.set_speaker(sp)
                eng.speak(
                    str(data.get("text", "")),
                    str(data.get("language", "ru")),
                    on_done=lambda: emit({"type": "tts.done"}),
                    on_error=lambda e: emit({"type": "tts.error", "message": e}),
                    on_level=lambda v: emit({"type": "tts.level", "level": v}),
                )
            elif t == "tts.stop":
                eng.stop()
            elif t == "ping":
                emit({"type": "pong"})
    except websockets.ConnectionClosed:
        pass
    finally:
        send_task.cancel()
        eng.stop()


async def _main(args) -> None:
    eng = XttsEngine()
    if eng.init_error:
        # Surface why the ML deps didn't import (frozen-build diagnostics).
        print(f"EVS_TTS_DIAG {eng.init_error}", file=sys.stderr, flush=True)

    async def handler(ws):
        await _handle(ws, eng)

    async with websockets.serve(handler, args.host, args.port) as server:
        port = args.port or server.sockets[0].getsockname()[1]
        print(f"EVS_TTS_READY {port}", flush=True)
        await asyncio.Future()


def main() -> None:
    ap = argparse.ArgumentParser(description="EVS XTTS voice-clone sidecar")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=0)
    args = ap.parse_args()
    try:
        asyncio.run(_main(args))
    except KeyboardInterrupt:
        pass
    except Exception as e:  # pragma: no cover
        print(f"EVS_TTS_ERROR {e}", file=sys.stderr, flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
