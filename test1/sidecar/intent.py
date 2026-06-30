"""Deterministic + fuzzy phrase -> command matching.

The Flutter app already does exact/contains matching in Dart; the sidecar adds
fuzzy/semantic-ish ranking via rapidfuzz (falls back to difflib if missing).
"""
from __future__ import annotations

try:
    from rapidfuzz import fuzz

    def _ratio(a: str, b: str) -> float:
        return fuzz.token_set_ratio(a, b) / 100.0
except Exception:  # pragma: no cover - fallback when rapidfuzz is absent
    import difflib

    def _ratio(a: str, b: str) -> float:
        return difflib.SequenceMatcher(None, a, b).ratio()


def _norm(s: str) -> str:
    return " ".join(s.lower().strip().split())


def match(text: str, commands: list[dict], threshold: float = 0.5) -> dict | None:
    """Return {"index", "score", "command"} for the best match, or None.

    `commands` is a list of {"phrase": str, ...} dicts (the EVS catalog).
    """
    t = _norm(text)
    if not t or not commands:
        return None
    best = None
    best_score = 0.0
    for i, c in enumerate(commands):
        phrase = _norm(str(c.get("phrase", "")))
        if not phrase:
            continue
        if t == phrase:
            score = 1.0
        elif phrase in t or t in phrase:
            score = 0.9
        else:
            score = _ratio(t, phrase)
        if score > best_score:
            best_score = score
            best = {"index": i, "score": round(score, 3), "command": c}
    if best is None or best_score < threshold:
        return None
    return best
