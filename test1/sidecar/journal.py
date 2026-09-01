"""Event journal — the first half of the bus in `anima project/anima-event-bus-spec.md`.

Deliberately the journal and nothing else: sources write here, and for now
nothing reads. That ordering is on purpose. A filter tuned against imagined
traffic is guesswork; a week of real rows shows what actually arrives, how
often, and how much of it would have deserved to be said out loud. The
`outcome` column is where the filter will later record which step an event
died on — until one exists, every row reads "journalled".

The database path is never derived in here. It arrives over `journal.config`
from the app, which alone knows its own data root and which drive it sits on.
"""
from __future__ import annotations

import json
import sqlite3
import threading
import uuid
from datetime import datetime, timezone

_SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
  id       TEXT PRIMARY KEY,
  ts       TEXT NOT NULL,
  source   TEXT NOT NULL,
  type     TEXT NOT NULL,
  severity TEXT NOT NULL,
  subject  TEXT,
  payload  TEXT,
  outcome  TEXT NOT NULL DEFAULT 'journalled'
);
CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(type);
"""


def new_event(source, etype, severity="info", subject=None, payload=None):
    """A fact, not a command: the source reports what happened, never what to
    do about it (principle 2 of the spec)."""
    return {
        "id": uuid.uuid4().hex,
        "ts": datetime.now(timezone.utc).astimezone().isoformat(
            timespec="milliseconds"),
        "source": source,
        "type": etype,
        "severity": severity,
        "subject": subject or {},
        "payload": payload or {},
    }


class Journal:
    """Append-only SQLite log.

    Writes arrive from polling threads, so one connection is shared under a
    lock rather than opened per thread: the traffic is a few rows a minute,
    and a single lock is easier to reason about than a pool.
    """

    def __init__(self, path: str) -> None:
        self.path = path
        self._lock = threading.Lock()
        self._db = sqlite3.connect(path, check_same_thread=False)
        # WAL so that a reader — the log window, eventually — never blocks the
        # writer, and an unclean exit costs the last row instead of the file.
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.executescript(_SCHEMA)
        self._db.commit()

    def write(self, event: dict, outcome: str = "journalled") -> None:
        row = (
            event["id"], event["ts"], event["source"], event["type"],
            event.get("severity", "info"),
            json.dumps(event.get("subject") or {}, ensure_ascii=False),
            json.dumps(event.get("payload") or {}, ensure_ascii=False),
            outcome,
        )
        with self._lock:
            self._db.execute(
                "INSERT OR REPLACE INTO events"
                " (id, ts, source, type, severity, subject, payload, outcome)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?)", row)
            self._db.commit()

    def recent(self, limit: int = 50) -> list:
        with self._lock:
            cur = self._db.execute(
                "SELECT ts, source, type, severity, subject, payload, outcome"
                " FROM events ORDER BY ts DESC LIMIT ?", (limit,))
            rows = cur.fetchall()
        return [{"ts": ts, "source": src, "type": etype, "severity": sev,
                 "subject": json.loads(subj or "{}"),
                 "payload": json.loads(pl or "{}"), "outcome": outcome}
                for ts, src, etype, sev, subj, pl, outcome in rows]

    def close(self) -> None:
        with self._lock:
            try:
                self._db.close()
            except Exception:
                pass
