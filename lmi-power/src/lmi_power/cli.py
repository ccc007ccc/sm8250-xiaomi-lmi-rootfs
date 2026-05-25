import argparse
import os
import re
import subprocess
import sys
from typing import Optional

from . import keymap, sysfs
from .backlight import BacklightController
from .config import PolicyConfig
from .policy import PolicyInputs, PolicyState, decide


def _fmt(value: object) -> str:
    return "unknown" if value is None else str(value)


def _service_active(name: str) -> bool:
    try:
        return subprocess.run(["systemctl", "is-active", "--quiet", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    except OSError:
        return False


def _service_enabled(name: str) -> bool:
    try:
        return subprocess.run(["systemctl", "is-enabled", "--quiet", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    except OSError:
        return False


def _warn_daemon() -> None:
    if _service_active("lmi-powerd.service"):
        print("warning: lmi-powerd is running; manual changes may be overwritten on the next policy poll", file=sys.stderr)


def parse_current(value: str) -> int:
    match = re.fullmatch(r"([0-9]+)([uU]?[aA]|[mM][aA])?", value.strip())
    if not match:
        raise argparse.ArgumentTypeError("expected an integer with optional uA or mA suffix")
    amount = int(match.group(1))
    suffix = match.group(2)
    if suffix and suffix.lower() == "ma":
        amount *= 1000
    if amount <= 0:
        raise argparse.ArgumentTypeError("current must be positive")
    return amount


def cmd_status(_: argparse.Namespace) -> int:
    config = PolicyConfig.from_env()
    battery = sysfs.read_battery_state()
    charger = sysfs.read_charger_state()
    _, decision = decide(
        config,
        PolicyState(),
        PolicyInputs(
            capacity=battery.capacity,
            temp_decic=battery.temp_decic,
            charge_behaviour=charger.charge_behaviour,
            input_current_limit_target_ua=charger.input_current_limit_target_ua,
            input_current_limit_effective_ua=charger.input_current_limit_effective_ua,
        ),
    )
    fields = {
        "battery_capacity": battery.capacity,
        "battery_temp_decic": battery.temp_decic,
        "battery_status": battery.status,
        "battery_current_now_ua": battery.current_now_ua,
        "battery_voltage_now_uv": battery.voltage_now_uv,
        "charger_online": charger.online,
        "charger_status": charger.status,
        "charger_usb_type": charger.usb_type,
        "charger_current_now_ua": charger.current_now_ua,
        "charger_voltage_now_uv": charger.voltage_now_uv,
        "charge_behaviour": charger.charge_behaviour,
        "input_current_limit_target_ua": _fmt(charger.input_current_limit_target_ua),
        "input_current_limit_effective_ua": _fmt(charger.input_current_limit_effective_ua),
        "input_limit_mismatch": int(sysfs.input_limit_mismatch(charger.input_current_limit_target_ua, charger.input_current_limit_effective_ua)),
        "policy_target_behaviour": decision.target_behaviour,
        "policy_target_input_current_ua": decision.target_input_current_ua,
        "policy_reason": decision.reason,
    }
    for key, value in fields.items():
        print(f"{key}={value}")
    return 0


def cmd_policy(_: argparse.Namespace) -> int:
    config = PolicyConfig.from_env()
    for key, value in config.__dict__.items():
        print(f"{key}={value}")
    errors = config.validate()
    if errors:
        for error in errors:
            print(f"invalid_config={error}")
        return 2
    print("scope=conservative_charge_limit_and_temperature_protection")
    print("hardware_bypass=false")
    return 0


def cmd_charge(args: argparse.Namespace) -> int:
    _warn_daemon()
    sysfs.write_charge_behaviour(args.behaviour)
    print(f"charge_behaviour={sysfs.read_active_charge_behaviour()}")
    return 0


def cmd_limit(args: argparse.Namespace) -> int:
    _warn_daemon()
    before = sysfs.read_optional_int(sysfs.charger_path("input_current_limit"))
    sysfs.write_input_current_limit(args.current_ua)
    target = sysfs.read_optional_int(sysfs.charger_path("input_current_limit"))
    effective = sysfs.read_optional_int(sysfs.charger_path("current_max"))
    print(f"input_current_limit_before_ua={_fmt(before)}")
    print(f"input_current_limit_target_ua={_fmt(target)}")
    print(f"input_current_limit_effective_ua={_fmt(effective)}")
    print(f"input_limit_mismatch={int(sysfs.input_limit_mismatch(target, effective))}")
    return 0


def _print_backlight_status(controller: BacklightController) -> int:
    status = controller.status()
    if status is None:
        print("backlight=missing")
        return 1
    print(f"path={status.path}")
    print(f"brightness={status.brightness}")
    print(f"actual_brightness={status.actual_brightness}")
    print(f"max_brightness={status.max_brightness}")
    print(f"bl_power={status.bl_power}")
    print(f"fb_blank={_fmt(status.fb_blank)}")
    print(f"forced_off={int(status.forced_off)}")
    print(f"is_off={int(status.is_off)}")
    return 0


def cmd_backlight(args: argparse.Namespace) -> int:
    controller = BacklightController(log=lambda message: print(message, file=sys.stderr))
    if args.action == "status":
        return _print_backlight_status(controller)
    if args.action == "on":
        return 0 if controller.set_on() else 1
    if args.action == "off":
        return 0 if controller.set_off() else 1
    if args.action == "toggle":
        return 0 if controller.toggle() else 1
    if args.action == "brightness":
        return 0 if controller.set_brightness(args.value) else 1
    raise AssertionError(args.action)


def _print_keymap(mapping: dict[str, str]) -> None:
    for key in keymap.KEYS:
        print(f"{key}={mapping[key]}")


def cmd_keys(args: argparse.Namespace) -> int:
    if args.keys_action == "status":
        _print_keymap(keymap.load_keymap())
        return 0
    if args.keys_action == "set":
        mapping = keymap.set_key_action(args.key, args.action)
        _print_keymap(mapping)
        if _service_active("lmi-power-keysd.service"):
            print("note=changes_apply_on_next_key_event")
        return 0
    if args.keys_action == "reset":
        mapping = keymap.reset_keymap()
        _print_keymap(mapping)
        return 0
    if args.keys_action == "actions":
        for action in keymap.ACTIONS:
            print(action)
        return 0
    raise AssertionError(args.keys_action)


def _check_path(path: str, failures: list[str]) -> None:
    if os.path.exists(path):
        print(f"ok path={path}")
    else:
        print(f"missing path={path}")
        failures.append(f"missing:{path}")


def cmd_validate(_: argparse.Namespace) -> int:
    failures: list[str] = []
    for path in sysfs.required_paths():
        _check_path(path, failures)
    for path in (
        "/usr/local/bin/lmi-power",
        "/usr/local/sbin/lmi-powerd",
        "/usr/local/sbin/lmi-power-keysd",
        "/etc/lmi-power/keys.conf",
        "/etc/systemd/system/lmi-powerd.service",
        "/etc/systemd/system/lmi-power-keysd.service",
    ):
        _check_path(path, failures)

    for service in ("lmi-powerd.service", "lmi-power-keysd.service"):
        print(f"service_active name={service} value={int(_service_active(service))}")
        print(f"service_enabled name={service} value={int(_service_enabled(service))}")

    for service in ("lmi-battery-protect.service", "lmi-debug-keys.service"):
        active = _service_active(service)
        enabled = _service_enabled(service)
        print(f"legacy_service name={service} active={int(active)} enabled={int(enabled)}")
        if active or enabled:
            failures.append(f"legacy_service_running:{service}")

    status_path = sysfs.charger_path("status")
    _check_path(status_path, failures)
    print("charger_status_control=read_only_expected")
    return 1 if failures else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="lmi-power")
    sub = parser.add_subparsers(dest="command", required=True)

    status = sub.add_parser("status")
    status.set_defaults(func=cmd_status)

    policy = sub.add_parser("policy")
    policy.set_defaults(func=cmd_policy)

    charge = sub.add_parser("charge")
    charge.add_argument("behaviour", choices=("auto", "inhibit"))
    charge.set_defaults(func=lambda args: cmd_charge(argparse.Namespace(behaviour="inhibit-charge" if args.behaviour == "inhibit" else "auto")))

    limit = sub.add_parser("limit")
    limit.add_argument("current_ua", type=parse_current)
    limit.set_defaults(func=cmd_limit)

    backlight = sub.add_parser("backlight")
    backlight.add_argument("action", choices=("status", "on", "off", "toggle", "brightness"))
    backlight.add_argument("value", nargs="?", type=int)
    backlight.set_defaults(func=cmd_backlight)

    keys = sub.add_parser("keys")
    keys_sub = keys.add_subparsers(dest="keys_action", required=True)
    keys_status = keys_sub.add_parser("status")
    keys_status.set_defaults(func=cmd_keys)
    keys_set = keys_sub.add_parser("set")
    keys_set.add_argument("key", choices=keymap.KEYS)
    keys_set.add_argument("action", choices=keymap.ACTIONS)
    keys_set.set_defaults(func=cmd_keys)
    keys_reset = keys_sub.add_parser("reset")
    keys_reset.set_defaults(func=cmd_keys)
    keys_actions = keys_sub.add_parser("actions")
    keys_actions.set_defaults(func=cmd_keys)

    validate = sub.add_parser("validate")
    validate.set_defaults(func=cmd_validate)
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "backlight" and args.action == "brightness" and args.value is None:
        parser.error("backlight brightness requires a value")
    try:
        return args.func(args)
    except PermissionError as exc:
        print(f"error=permission_denied path={exc.filename} hint=run_with_sudo", file=sys.stderr)
        return 1
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
