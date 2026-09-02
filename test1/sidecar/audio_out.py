"""Устройства вывода звука: перечислить и переключить.

Перечисление — документированный Core Audio (IMMDeviceEnumerator), а вот смены
устройства по умолчанию в публичном API Windows нет вообще. Она делается через
IPolicyConfig — интерфейс недокументированный, но существующий со времён Vista
и стабильный: на нём работают все переключалки звука. Обещания Microsoft за ним
нет, поэтому каждый вызов обёрнут, а неудача возвращается как результат, а не
как исключение.

Роли переключаются ДВЕ из трёх: eConsole и eMultimedia — то, что в панели звука
называется «устройство по умолчанию». eCommunications не трогается намеренно:
гарнитуру для разговоров держат отдельно от того, где играет музыка, и увести
её вместе с остальным значило бы сломать связь ради громкости.
"""
from __future__ import annotations

import ctypes

_RENDER = 0        # EDataFlow.eRender
_STATE_ALL = 0x0f  # DEVICE_STATEMASK_ALL

_STATE_NAMES = {1: "active", 2: "disabled", 4: "absent", 8: "unplugged"}

# Роли: 0 eConsole, 1 eMultimedia, 2 eCommunications.
_ROLES = (0, 1)


def _co_init() -> None:
    try:
        import comtypes
        comtypes.CoInitialize()
    except Exception:
        pass


def _policy_config():
    """Клиент IPolicyConfig. Методы до SetDefaultEndpoint не описаны — они и не
    нужны, но занять их места в таблице обязательно: COM зовёт по номеру, и
    пропуск любого из них увёл бы вызов не в тот метод."""
    import comtypes
    from comtypes import GUID, COMMETHOD, HRESULT, IUnknown

    class IPolicyConfig(IUnknown):
        _iid_ = GUID("{f8679f50-850a-41cf-9c72-430f290290c8}")
        _methods_ = [
            COMMETHOD([], HRESULT, "Reserved%d" % i) for i in range(10)
        ] + [
            COMMETHOD([], HRESULT, "SetDefaultEndpoint",
                      (["in"], ctypes.c_wchar_p, "wszDeviceId"),
                      (["in"], ctypes.c_int, "role")),
            COMMETHOD([], HRESULT, "SetEndpointVisibility"),
        ]

    return comtypes.CoCreateInstance(
        GUID("{870af99c-171d-4f9e-af0d-e63df40c2bc9}"),
        IPolicyConfig, comtypes.CLSCTX_ALL)


def default_id() -> str:
    """Идентификатор нынешнего устройства вывода. Пусто — не удалось."""
    _co_init()
    try:
        from pycaw.pycaw import AudioUtilities
        return AudioUtilities.GetSpeakers().id or ""
    except Exception:
        return ""


def devices() -> list:
    """Все выходы, включая выключенные и невоткнутые.

    Невоткнутые нужны в списке обязательно: наушники называют один раз, а
    втыкают каждый день, и устройство, пропавшее из списка вместе с джеком,
    невозможно было бы выбрать заранее.
    """
    _co_init()
    out = []
    try:
        from pycaw.pycaw import AudioUtilities
        from pycaw.constants import CLSID_MMDeviceEnumerator
        from pycaw.api.mmdeviceapi import IMMDeviceEnumerator
        import comtypes

        enumerator = comtypes.CoCreateInstance(
            CLSID_MMDeviceEnumerator, IMMDeviceEnumerator, comtypes.CLSCTX_ALL)
        collection = enumerator.EnumAudioEndpoints(_RENDER, _STATE_ALL)
        cur = default_id()
        for i in range(collection.GetCount()):
            dev = collection.Item(i)
            try:
                info = AudioUtilities.CreateDevice(dev)
            except Exception:
                continue
            name = (info.FriendlyName or "").strip()
            if not name:
                continue
            # state — перечисление pycaw, а не число: int() на нём падает, и
            # раньше это уносило в общий except весь список целиком.
            st = getattr(info.state, "value", info.state)
            out.append({
                "id": info.id,
                "name": name,
                "state": _STATE_NAMES.get(int(st), "unknown"),
                "default": info.id == cur,
            })
    except Exception:
        return out
    return out


def set_default(device_id: str) -> dict:
    """Сделать устройство выходом по умолчанию.

    Невоткнутое устройство переключением не становится рабочим — звук уехал бы
    в никуда и пропал совсем. Поэтому состояние проверяется до вызова, и отказ
    возвращается с причиной: тишина без объяснения неотличима от поломки.
    """
    did = (device_id or "").strip()
    if not did:
        return {"ok": False, "reason": "no_device"}
    known = {d["id"]: d for d in devices()}
    d = known.get(did)
    if d is None:
        return {"ok": False, "reason": "unknown_device"}
    if d["state"] != "active":
        return {"ok": False, "reason": d["state"], "name": d["name"]}
    if d["default"]:
        return {"ok": True, "name": d["name"], "changed": False}
    _co_init()
    try:
        pc = _policy_config()
        for role in _ROLES:
            pc.SetDefaultEndpoint(did, role)
    except Exception as e:
        return {"ok": False, "reason": "failed", "error": str(e)}
    return {"ok": default_id() == did, "name": d["name"], "changed": True}
