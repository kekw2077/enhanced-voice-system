"""Проверка фильтра шины.

Запуск:  python sidecar/bus_filter_test.py

Отдельным скриптом, а не под фреймворком: у питон-стороны его нет, а заводить
ради одного файла зависимость, которая поедет в сборку на 112 МБ, незачем.

Проверяется то, что ломается молча. Фильтр не падает и ничего не сообщает —
он просто перестаёт срабатывать там, где должен, или срабатывает там, где не
должен. Первое замечаешь через неделю, второе — когда ассистент приглушил
музыку посреди разговора.
"""
from __future__ import annotations

import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bus_filter          # noqa: E402
from journal import Journal  # noqa: E402

_fails = []


def check(name, got, want):
    if got == want:
        print("  ok   %s" % name)
    else:
        print("  FAIL %s: получили %r, ждали %r" % (name, got, want))
        _fails.append(name)


def make_filter(rules_yaml=None, tools=None):
    db = os.path.join(tempfile.mkdtemp(prefix="animabus"), "events.db")
    journal = Journal(db)
    if rules_yaml is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "rules.yaml")
    else:
        path = os.path.join(os.path.dirname(db), "rules.yaml")
        with open(path, "w", encoding="utf-8") as f:
            f.write(rules_yaml)
    rules = bus_filter.load_rules(path)
    calls = []

    def tool_ok(args):
        calls.append(args)
        return True

    f = bus_filter.Filter(journal, rules,
                          tools if tools is not None else {
                              "audio.duck_music": tool_ok,
                              "audio.unduck_music": tool_ok,
                          })
    return f, calls, journal


def ev(etype, **kw):
    return bus_filter.make_event("test", etype, **kw)


print("правила из поставки")
f, calls, journal = make_filter()
check("правила загрузились", len(f.rules) >= 4, True)
check("игра пошла — приглушили",
      f.feed(ev("session.gaming.entered")), "acted:game-audio-duck")
check("инструмент получил список приложений", "apps" in calls[0], True)
check("уровень приглушения из правила", calls[0].get("level"), 20)
check("игра кончилась — вернули",
      f.feed(ev("session.gaming.exited")), "acted:game-audio-restore")

print()
print("порядок правил: частное выше общего")
check("горячая карта не съедена глушилкой",
      f.feed(ev("metrics.gpu.hot", payload={"temp_c": 91})),
      "raise_undelivered:gpu-hot")
check("тёплая карта проваливается в глушилку",
      f.feed(ev("metrics.gpu.hot", payload={"temp_c": 70})),
      "dropped:metrics-noise")
check("прочие метрики — в глушилку",
      f.feed(ev("metrics.cpu.high", payload={"pct": 99})),
      "dropped:metrics-noise")
check("незнакомое событие никуда не подходит",
      f.feed(ev("nc.log.error")), "unmatched")

print()
print("шаг 0: протухшее и повторы")
RULES = """
- id: everything
  match: {type: "t.*"}
  action: ACT
  tool: noop
"""
f2, _, _ = make_filter(RULES, tools={"noop": lambda a: True})
e = ev("t.one", severity="info")
e["_received"] = e["_received"] - 60          # событие из прошлого
e["ttl_s"] = 10
check("протухшее выброшено", f2.feed(e), "expired")
d1 = ev("t.two"); d1["dedup_key"] = "k"; d1["cooldown_s"] = 300
d2 = ev("t.two"); d2["dedup_key"] = "k"; d2["cooldown_s"] = 300
check("первое проходит", f2.feed(d1), "acted:everything")
check("повтор поглощён", f2.feed(d2), "deduped")

print()
print("потолок подтверждений")
f3, calls3, _ = make_filter(RULES, tools={"noop": lambda a: True})
f3.confirm = bus_filter.CONFIRM_ALWAYS
check("при «Всегда» молчаливого действия не бывает",
      f3.feed(ev("t.x")), "ask_undelivered:everything")
f4, _, _ = make_filter(RULES, tools={"noop": lambda a: True})
f4.confirm = bus_filter.CONFIRM_NEVER
check("«Никогда» не превращает вопрос в действие",
      f4.feed(ev("t.x")), "acted:everything")

print()
print("белый список инструментов")
f5, _, _ = make_filter(RULES, tools={})
check("незнакомый инструмент не выполняется",
      f5.feed(ev("t.x")), "act_failed:everything")

print()
print("шаг 2: бюджет")
ASKING = """
- id: chatty
  match: {type: "t.*"}
  action: RAISE
"""
f6, _, _ = make_filter(ASKING)
f6.session = "gaming"                      # три реплики в час
got = [f6.feed(ev("t.%d" % i)) for i in range(5)]
check("первые три прошли",
      [g.startswith("raise") for g in got[:3]], [True, True, True])
check("четвёртая и пятая упёрлись в квоту", got[3:], ["over_budget"] * 2)
f6.session = "idle"
check("вне игры квоты нет",
      f6.feed(ev("t.later")).startswith("raise"), True)
f6.session = "gaming"
check("тревога квоту игнорирует",
      f6.feed(ev("t.alarm", severity="alert")).startswith("raise"), True)

print()
print("сравнения и списки из настроек")
SET = """
- id: known-game
  match: {type: "process.started", subject.app: "in:settings.games.list"}
  action: ACT
  tool: noop
"""
f7, _, _ = make_filter(SET, tools={"noop": lambda a: True})
f7.settings = {"games": {"list": ["VALORANT-Win64-Shipping.exe"]}}
check("игра из списка узнана",
      f7.feed(ev("process.started",
                 subject={"app": "valorant-win64-shipping.exe"})),
      "acted:known-game")
check("чужой процесс не узнан",
      f7.feed(ev("process.started", subject={"app": "notepad.exe"})),
      "unmatched")

print()
print("журнал")
rows = journal.recent(20)
check("исходы попали в журнал", len(rows) >= 5, True)
check("у отброшенного записан шаг, на котором он умер",
      any(r["outcome"].startswith("dropped:") for r in rows), True)
check("у сработавшего записано правило",
      any(r["outcome"] == "acted:game-audio-duck" for r in rows), True)

print()
if _fails:
    print("ПРОВАЛЕНО: %d" % len(_fails))
    for n in _fails:
        print("  -", n)
    sys.exit(1)
print("всё сошлось")
