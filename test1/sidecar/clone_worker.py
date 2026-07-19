#!/usr/bin/env python
"""EVS voice-clone worker (XTTS-v2, CPU).

A persistent child process the EVS sidecar spawns once. It loads the XTTS model
a single time, caches the speaker "fingerprint" (GPT conditioning latents +
speaker embedding) per reference sample, then synthesizes on demand. Speaking to
it is a line protocol: one JSON object per line on stdin, one JSON reply per line
on stdout. ALL logging goes to stderr so stdout stays a clean protocol channel.

Protocol (stdin -> stdout):
  {"cmd":"ping"}                              -> {"ok":true,"event":"pong"}
  {"cmd":"setref","ref":"C:/a.wav"}           -> {"ok":true,"event":"ref","ms":N}
  {"cmd":"synth","text":"...","out":"o.wav",
        "lang":"ru","speed":1.0}              -> {"ok":true,"event":"synth","out":"o.wav","ms":N,"dur":S}
  {"cmd":"quit"}                              -> exits
On startup, after the model loads:            {"ok":true,"event":"ready","ms":N,"sr":24000}
Any failure:                                  {"ok":false,"event":<cmd>,"err":"..."}
"""
import os, sys, json, time, wave
import numpy as np

os.environ["COQUI_TOS_AGREED"] = "1"
os.environ.setdefault("OMP_NUM_THREADS", str(os.cpu_count() or 4))


def log(*a):
    print("[clone_worker]", *a, file=sys.stderr, flush=True)


def reply(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def write_wav(path, wav, sr):
    x = np.asarray(wav, dtype=np.float32)
    pk = float(np.max(np.abs(x))) + 1e-9
    if pk > 0.99:
        x = x * (0.99 / pk)
    pcm = (x * 32767.0).astype("<i2")
    w = wave.open(path, "wb")
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(int(sr))
    w.writeframes(pcm.tobytes()); w.close()
    return len(pcm) / float(sr)


class XttsWorker:
    def __init__(self):
        self.model = None
        self.sr = 24000
        self._ref = None            # currently loaded reference path
        self._gpt = None            # cached gpt_cond_latent
        self._spk = None            # cached speaker_embedding

    def _model_dir(self):
        # Prefer an explicit dir (dev), then the model bundled next to the frozen
        # exe (production: _internal/xtts_model), else None -> network fallback.
        d = os.environ.get("EVS_XTTS_DIR", "").strip()
        if d and os.path.isfile(os.path.join(d, "config.json")):
            return d
        base = getattr(sys, "_MEIPASS", None) or os.path.dirname(os.path.abspath(__file__))
        cand = os.path.join(base, "xtts_model")
        if os.path.isfile(os.path.join(cand, "config.json")):
            return cand
        return None

    def load(self):
        t = time.time()
        import torch
        torch.set_num_threads(int(os.environ.get("OMP_NUM_THREADS", "4")))
        model_dir = self._model_dir()
        if model_dir:
            # Local, offline load — no download, no license gate.
            from TTS.tts.configs.xtts_config import XttsConfig
            from TTS.tts.models.xtts import Xtts
            config = XttsConfig()
            config.load_json(os.path.join(model_dir, "config.json"))
            model = Xtts.init_from_config(config)
            model.load_checkpoint(config, checkpoint_dir=model_dir,
                                  use_deepspeed=False, eval=True)
            model.cpu()
            self.model = model
            self.sr = int(getattr(getattr(config, "audio", None),
                                  "output_sample_rate", 24000) or 24000)
            log("model loaded (local %s) in %.1fs sr=%d" %
                (model_dir, time.time() - t, self.sr))
        else:
            from TTS.api import TTS   # dev fallback: downloads the model
            tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to("cpu")
            self.model = tts.synthesizer.tts_model
            self.sr = int(getattr(tts.synthesizer, "output_sample_rate", 24000))
            log("model loaded (network) in %.1fs sr=%d" % (time.time() - t, self.sr))
        return time.time() - t

    def set_ref(self, ref):
        if not ref or not os.path.isfile(ref):
            raise RuntimeError("reference wav not found: %r" % ref)
        if ref == self._ref and self._gpt is not None:
            return 0.0
        t = time.time()
        gpt, spk = self.model.get_conditioning_latents(audio_path=[ref])
        self._ref, self._gpt, self._spk = ref, gpt, spk
        return time.time() - t

    def _infer(self, text, lang, speed):
        # Stabilized decoding: repetition_penalty + top_k/top_p + length_penalty
        # curb XTTS's occasional short-phrase "runaway" (endless babble). Text
        # splitting keeps long replies coherent sentence by sentence.
        return self.model.inference(
            text, lang, self._gpt, self._spk,
            temperature=0.65, repetition_penalty=5.0, top_k=50, top_p=0.85,
            length_penalty=1.0, speed=float(speed), enable_text_splitting=True,
        )

    def synth(self, text, out, lang="ru", speed=1.0):
        if self._gpt is None:
            raise RuntimeError("no reference set")
        text = (text or "").strip()
        if not text:
            raise RuntimeError("empty text")
        if len(text) < 3:                 # pad ultra-short tokens ("Да") for stability
            text = text + " …"
        try:
            r = self._infer(text, lang, speed)
        except Exception as e:            # one retry — XTTS decode is stochastic
            log("synth retry after: %r" % e)
            r = self._infer(text, lang, speed)
        dur = write_wav(out, r["wav"], self.sr)
        return dur


def main():
    w = XttsWorker()
    try:
        ms = w.load()
        reply({"ok": True, "event": "ready", "ms": int(ms * 1000), "sr": w.sr})
    except Exception as e:  # noqa
        reply({"ok": False, "event": "ready", "err": repr(e)})
        return 1
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception as e:  # noqa
            reply({"ok": False, "event": "parse", "err": repr(e)})
            continue
        cmd = msg.get("cmd")
        try:
            if cmd == "ping":
                reply({"ok": True, "event": "pong"})
            elif cmd == "setref":
                t = w.set_ref(msg.get("ref"))
                reply({"ok": True, "event": "ref", "ms": int(t * 1000)})
            elif cmd == "synth":
                if "ref" in msg:                      # inline ref switch
                    w.set_ref(msg["ref"])
                t = time.time()
                dur = w.synth(msg.get("text", ""), msg.get("out"),
                              msg.get("lang", "ru"), msg.get("speed", 1.0))
                reply({"ok": True, "event": "synth", "out": msg.get("out"),
                       "ms": int((time.time() - t) * 1000), "dur": round(dur, 3)})
            elif cmd == "quit":
                reply({"ok": True, "event": "bye"})
                break
            else:
                reply({"ok": False, "event": "unknown", "err": "cmd=%r" % cmd})
        except Exception as e:  # noqa
            reply({"ok": False, "event": cmd or "?", "err": repr(e)})
    return 0


if __name__ == "__main__":
    sys.exit(main())
