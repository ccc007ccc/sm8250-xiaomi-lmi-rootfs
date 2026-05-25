import os
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

BATTERY = os.environ.get("LMI_POWER_BATTERY_PATH", "/sys/class/power_supply/qcom-battery")
CHARGER = os.environ.get("LMI_POWER_CHARGER_PATH", "/sys/class/power_supply/pm8150b-charger")


@dataclass(frozen=True)
class BatteryState:
    capacity: int
    temp_decic: int
    status: str
    current_now_ua: int
    voltage_now_uv: int


@dataclass(frozen=True)
class ChargerState:
    online: int
    status: str
    current_now_ua: int
    voltage_now_uv: int
    usb_type: str
    raw_charge_behaviour: str
    charge_behaviour: str
    input_current_limit_target_ua: Optional[int]
    input_current_limit_effective_ua: Optional[int]


def battery_path(name: str) -> str:
    return str(Path(BATTERY) / name)


def charger_path(name: str) -> str:
    return str(Path(CHARGER) / name)


def required_paths() -> list[str]:
    return [
        battery_path("capacity"),
        battery_path("temp"),
        battery_path("status"),
        battery_path("current_now"),
        battery_path("voltage_now"),
        charger_path("online"),
        charger_path("status"),
        charger_path("current_now"),
        charger_path("voltage_now"),
        charger_path("charge_behaviour"),
        charger_path("input_current_limit"),
        charger_path("current_max"),
    ]


def read_text(path: str, default: Optional[str] = None) -> str:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        if default is not None:
            return default
        raise


def read_int(path: str, default: Optional[int] = None) -> int:
    try:
        return int(read_text(path))
    except (OSError, ValueError):
        if default is not None:
            return default
        raise


def read_optional_int(path: str) -> Optional[int]:
    try:
        return read_int(path)
    except (OSError, ValueError):
        return None


def write_text(path: str, value: object) -> None:
    with open(path, "w", encoding="utf-8") as f:
        f.write(str(value))


def active_charge_behaviour(text: str) -> str:
    for token in text.split():
        if token.startswith("[") and token.endswith("]"):
            return token[1:-1]
    return text.strip()


def read_battery_state() -> BatteryState:
    return BatteryState(
        capacity=read_int(battery_path("capacity")),
        temp_decic=read_int(battery_path("temp")),
        status=read_text(battery_path("status")),
        current_now_ua=read_int(battery_path("current_now")),
        voltage_now_uv=read_int(battery_path("voltage_now")),
    )


def read_charger_state() -> ChargerState:
    raw_behaviour = read_text(charger_path("charge_behaviour"))
    return ChargerState(
        online=read_int(charger_path("online")),
        status=read_text(charger_path("status"), "unknown"),
        current_now_ua=read_int(charger_path("current_now"), 0),
        voltage_now_uv=read_int(charger_path("voltage_now"), 0),
        usb_type=read_text(charger_path("usb_type"), "unknown"),
        raw_charge_behaviour=raw_behaviour,
        charge_behaviour=active_charge_behaviour(raw_behaviour),
        input_current_limit_target_ua=read_optional_int(charger_path("input_current_limit")),
        input_current_limit_effective_ua=read_optional_int(charger_path("current_max")),
    )


def read_active_charge_behaviour() -> str:
    return active_charge_behaviour(read_text(charger_path("charge_behaviour")))


def write_charge_behaviour(value: str) -> None:
    if value not in ("auto", "inhibit-charge"):
        raise ValueError(f"unsupported charge behaviour: {value}")
    write_text(charger_path("charge_behaviour"), value)


def write_input_current_limit(value_ua: int) -> None:
    if value_ua <= 0:
        raise ValueError("input current limit must be positive")
    write_text(charger_path("input_current_limit"), value_ua)


def input_limit_mismatch(target_ua: Optional[int], effective_ua: Optional[int]) -> bool:
    return target_ua is not None and effective_ua is not None and target_ua != effective_ua
