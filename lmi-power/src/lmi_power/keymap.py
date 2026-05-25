import os
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

KEYMAP_PATH = os.environ.get("LMI_POWER_KEYMAP_PATH", "/etc/lmi-power/keys.conf")
KEYS = ("power", "volume-up", "volume-down")
ACTIONS = ("toggle-backlight", "backlight-on", "backlight-off", "brightness-up", "brightness-down", "none")
DEFAULT_ACTIONS = {
    "power": "toggle-backlight",
    "volume-up": "brightness-up",
    "volume-down": "brightness-down",
}


@dataclass(frozen=True)
class KeyAction:
    key: str
    action: str


def default_keymap() -> dict[str, str]:
    return dict(DEFAULT_ACTIONS)


def validate_key(key: str) -> str:
    if key not in KEYS:
        raise ValueError(f"unsupported key: {key}")
    return key


def validate_action(action: str) -> str:
    if action not in ACTIONS:
        raise ValueError(f"unsupported key action: {action}")
    return action


def parse_keymap(text: str) -> dict[str, str]:
    mapping = default_keymap()
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, action = [part.strip() for part in line.split("=", 1)]
        if key not in KEYS or action not in ACTIONS:
            continue
        mapping[key] = action
    return mapping


def format_keymap(mapping: dict[str, str]) -> str:
    lines = ["# lmi-power key actions"]
    for key in KEYS:
        lines.append(f"{key}={validate_action(mapping.get(key, DEFAULT_ACTIONS[key]))}")
    return "\n".join(lines) + "\n"


def load_keymap(path: str = KEYMAP_PATH) -> dict[str, str]:
    try:
        return parse_keymap(Path(path).read_text(encoding="utf-8"))
    except OSError:
        return default_keymap()


def save_keymap(mapping: dict[str, str], path: str = KEYMAP_PATH) -> None:
    for key in KEYS:
        validate_action(mapping.get(key, DEFAULT_ACTIONS[key]))
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(format_keymap(mapping), encoding="utf-8")


def set_key_action(key: str, action: str, path: str = KEYMAP_PATH) -> dict[str, str]:
    key = validate_key(key)
    action = validate_action(action)
    mapping = load_keymap(path)
    mapping[key] = action
    save_keymap(mapping, path)
    return mapping


def reset_keymap(path: str = KEYMAP_PATH) -> dict[str, str]:
    mapping = default_keymap()
    save_keymap(mapping, path)
    return mapping


def action_for(key: str, path: str = KEYMAP_PATH, mapping: Optional[dict[str, str]] = None) -> str:
    validate_key(key)
    source = mapping if mapping is not None else load_keymap(path)
    return validate_action(source.get(key, DEFAULT_ACTIONS[key]))
