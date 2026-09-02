"""Фильтр шины: событие проходит шаги по порядку и на любом может умереть.

Разбирает ТОЛЬКО фоновые события. Голосовой путь (stt.final -> VoiceAssistant
-> CommandExecutor) идёт мимо и ничего об этом файле не знает: он работает
каждый день, и перекладывать его ради стройности значило бы менять работающее
на непроверенное.

Два принципа спецификации, за которые здесь держатся крепче остального:

  * событие — факт, а не команда. Источник сообщает, что случилось; что с этим
    делать, решают правила. Поэтому в самом событии нет ни действия, ни текста;
  * молчание — валидный исход. Большинство событий обязаны умирать в фильтре,
    и правило по умолчанию делает именно это.

Исходы пишутся в тот же журнал, что и события, в колонку outcome — она
заводилась ровно под это. По ней видно не только что произошло, но и на каком
шаге фильтр решил промолчать; без этого правила не отладить.
"""
from __future__ import annotations

import threading
import time

from journal import new_event

DROP, ACT, ASK, RAISE = "DROP", "ACT", "ASK", "RAISE"

# Потолок подтверждений, приходит из настроек приложения («Подтверждение перед
# выполнением»). Правило может спрашивать ЧАЩЕ, чем требует настройка, но
# никогда реже: настройка задаёт минимум осторожности, а не право молчать.
CONFIRM_ALWAYS, CONFIRM_DANGEROUS, CONFIRM_NEVER = "always", "dangerous", "never"
# Приложение называет среднее значение "risky" (настройка «Только опасные»).
# Принимается его словарь, а не свой: прослойка перевода — лишнее место, где
# два конца разъезжаются молча.
CONFIRM_ALIASES = {"risky": CONFIRM_DANGEROUS}


def normalize_confirm(value: str) -> str:
    v = str(value or "").strip().lower()
    v = CONFIRM_ALIASES.get(v, v)
    return v if v in (CONFIRM_ALWAYS, CONFIRM_DANGEROUS, CONFIRM_NEVER) else ""


def _dig(obj, path: str):
    """Значение по пути через точку: subject.app, payload.temp_c."""
    cur = obj
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def _as_number(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def _match_value(actual, expected, settings) -> bool:
    """Одно условие правила.

    Понимает четыре формы, все они взяты из примеров спецификации:
      "net.loss.high"            — точное совпадение;
      "metrics.*"                — префикс по иерархии типов;
      ">= 85"                    — сравнение чисел;
      "in:settings.games.list"   — вхождение в список из настроек.
    """
    if not isinstance(expected, str):
        return actual == expected

    if expected.startswith("in:"):
        ref = expected[3:].strip()
        if ref.startswith("settings."):
            ref = ref[len("settings."):]
        pool = _dig(settings, ref)
        if not isinstance(pool, (list, tuple, set)):
            return False
        a = str(actual or "").lower()
        return any(a == str(p).lower() for p in pool)

    for op in (">=", "<=", "==", "!=", ">", "<"):
        if expected.startswith(op):
            rhs = _as_number(expected[len(op):].strip())
            lhs = _as_number(actual)
            if rhs is None or lhs is None:
                return False
            if op == ">=":
                return lhs >= rhs
            if op == "<=":
                return lhs <= rhs
            if op == "==":
                return lhs == rhs
            if op == "!=":
                return lhs != rhs
            if op == ">":
                return lhs > rhs
            return lhs < rhs

    if expected.endswith(".*"):
        return str(actual or "").startswith(expected[:-1])
    if expected == "*":
        return actual is not None
    return str(actual) == expected


class Rule:
    def __init__(self, d: dict) -> None:
        self.id = str(d.get("id") or "")
        self.match = dict(d.get("match") or {})
        self.action = str(d.get("action") or DROP).upper()
        tools = d.get("tools")
        if tools is None:
            tools = [d["tool"]] if d.get("tool") else []
        self.tools = [str(t) for t in tools]
        self.args = dict(d.get("args") or {})
        self.say = d.get("say")
        self.cooldown_s = float(d.get("cooldown_s") or 0)
        self.continue_ = bool(d.get("continue") or False)

    def matches(self, event: dict, settings: dict) -> bool:
        for path, expected in self.match.items():
            if not _match_value(_dig(event, path), expected, settings):
                return False
        return True


def load_rules(path: str) -> list:
    """Правила из YAML. Порядок важен: побеждает первое совпавшее."""
    import yaml
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or []
    return [Rule(d) for d in data if isinstance(d, dict)]


class Budget:
    """Квота реплик.

    Token bucket, а не «не чаще раза в N секунд»: три события подряд — это
    обычный вечер, а вот четвёртое за час уже назойливость.
    """

    PER_HOUR = {"gaming": 3, "work": 6, "idle": 0}   # 0 = без ограничения

    def __init__(self) -> None:
        self._spent: dict = {}

    def allow(self, session: str, severity: str) -> bool:
        if severity == "alert":
            return True                      # тревога квоту игнорирует
        limit = self.PER_HOUR.get(session, 0)
        if limit <= 0:
            return True
        now = time.monotonic()
        marks = [t for t in self._spent.get(session, []) if now - t < 3600]
        if len(marks) >= limit:
            self._spent[session] = marks
            return False
        marks.append(now)
        self._spent[session] = marks
        return True


class Filter:
    """Единственный потребитель очереди.

    Один поток исполнения — чтобы порядок событий и расход бюджета были
    детерминированы; источники при этом живут каждый в своём.
    """

    def __init__(self, journal, rules: list, tools: dict) -> None:
        self.journal = journal
        self.rules = rules
        self.tools = tools
        self.settings: dict = {}
        self.session = "idle"
        self.confirm = CONFIRM_DANGEROUS
        self._budget = Budget()
        self._seen: dict = {}      # dedup_key -> (когда, сколько раз)
        self._said: dict = {}      # type -> когда озвучили в прошлый раз
        self._lock = threading.Lock()

    # ---- шаг 0: протухшее и повторы ------------------------------------
    def _step0(self, event: dict):
        born = event.get("_received")
        if born is None:
            born = time.monotonic()
        ttl = _as_number(event.get("ttl_s"))
        if ttl and time.monotonic() - born > ttl:
            return "expired"
        key = event.get("dedup_key")
        if key:
            now = time.monotonic()
            window = _as_number(event.get("cooldown_s")) or 0
            prev = self._seen.get(key)
            if prev and now - prev[0] < window:
                self._seen[key] = (prev[0], prev[1] + 1)
                return "deduped"
            self._seen[key] = (now, 1)
        return None

    # ---- шаг 1: правила ------------------------------------------------
    def _step1(self, event: dict) -> list:
        hits = []
        for rule in self.rules:
            if not rule.matches(event, self.settings):
                continue
            hits.append(rule)
            if not rule.continue_:
                break
        return hits

    # ---- шаг 2: бюджеты и потолок подтверждений ------------------------
    def _step2(self, event: dict, rule: Rule):
        action = rule.action
        # Настройка — потолок: при «Всегда» молчаливых действий не бывает и ACT
        # становится вопросом. Обратно это не работает — «Никогда» не
        # превращает вопрос в действие, иначе настройка стала бы разрешением
        # делать необратимое без спроса.
        if action == ACT and self.confirm == CONFIRM_ALWAYS:
            action = ASK
        if action in (ACT, DROP):
            return action, None              # молчаливое действие бюджет не тратит

        severity = str(event.get("severity") or "info")
        if not self._budget.allow(self.session, severity):
            return DROP, "over_budget"
        if rule.cooldown_s:
            last = self._said.get(event.get("type"))
            if last is not None and time.monotonic() - last < rule.cooldown_s:
                return DROP, "topic_cooldown"
            self._said[event.get("type")] = time.monotonic()
        return action, None

    # ---- исполнение ----------------------------------------------------
    def _run_tools(self, rule: Rule) -> bool:
        ok = True
        for name in rule.tools:
            fn = self.tools.get(name)
            if fn is None:
                ok = False       # белый список: незнакомое имя не выполняется
                continue
            try:
                if fn(dict(rule.args)) is False:
                    ok = False
            except Exception:
                ok = False
        return ok

    def feed(self, event: dict) -> str:
        """Прогнать событие и вернуть исход. В журнал пишется в любом случае."""
        with self._lock:
            outcome = self._feed_locked(event)
        try:
            self.journal.write(event, outcome)
        except Exception:
            pass
        return outcome

    def _feed_locked(self, event: dict) -> str:
        dead = self._step0(event)
        if dead:
            return dead
        hits = self._step1(event)
        if not hits:
            return "unmatched"
        outcomes = []
        for rule in hits:
            action, why = self._step2(event, rule)
            if action == DROP:
                outcomes.append(why or "dropped:" + rule.id)
            elif action == ACT:
                ok = self._run_tools(rule)
                outcomes.append(("acted:" if ok else "act_failed:") + rule.id)
            elif action == ASK:
                # Спросить пока некого: канала «вопрос -> ответ» между шиной и
                # интерфейсом ещё нет. Ничего не делаем и говорим об этом в
                # журнале: сделать необратимое без ответа хуже, чем не сделать.
                outcomes.append("ask_undelivered:" + rule.id)
            else:
                outcomes.append("raise_undelivered:" + rule.id)
        return ";".join(outcomes)


def default_tools() -> dict:
    """Белый список инструментов.

    Здесь только то, что уже работает и что обратимо. Переключения устройства
    вывода в нём нет намеренно: публичного API для этого в Windows не
    существует, а без проверки, что наушники реально подключены, звук уедет в
    отсутствующее устройство — то есть пропадёт совсем.
    """

    def _set_level(args, default_pct):
        import app_audio
        apps = args.get("apps") or []
        pct = _as_number(args.get("level"))
        pct = default_pct if pct is None else pct
        level = max(0.0, min(1.0, pct / 100.0))
        done = False
        for app in apps:
            if app_audio.apply(str(app), "set", level).get("ok"):
                done = True
        return done

    return {
        "audio.duck_music": lambda args: _set_level(args, 20.0),
        "audio.unduck_music": lambda args: _set_level(args, 100.0),
    }


def make_event(source, etype, **kw) -> dict:
    """Событие со временем получения — по нему шаг 0 считает ttl."""
    ev = new_event(source, etype, **kw)
    ev["_received"] = time.monotonic()
    return ev
