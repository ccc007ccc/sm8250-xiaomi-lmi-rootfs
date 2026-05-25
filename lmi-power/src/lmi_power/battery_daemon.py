import os
import time

from . import sysfs
from .config import PolicyConfig
from .policy import PolicyInputs, PolicyState, decide


def _value(value: object) -> str:
    return str(value).replace(" ", "_")


def log(**fields: object) -> None:
    print(" ".join(f"{key}={_value(value)}" for key, value in fields.items()), flush=True)


def wait_for_sysfs(config: PolicyConfig) -> bool:
    deadline = time.monotonic() + config.wait_seconds
    next_log = 0.0
    while time.monotonic() < deadline:
        missing = [path for path in sysfs.required_paths() if not os.path.exists(path)]
        if not missing:
            return True
        now = time.monotonic()
        if now >= next_log:
            log(event="waiting_sysfs", missing=",".join(missing))
            next_log = now + 5
        time.sleep(1)

    missing = [path for path in sysfs.required_paths() if not os.path.exists(path)]
    log(event="missing_sysfs", missing=",".join(missing))
    return False


def set_charge_behaviour(target: str) -> bool:
    try:
        current = sysfs.read_active_charge_behaviour()
    except OSError as exc:
        log(event="read_failed", path=sysfs.charger_path("charge_behaviour"), error=exc)
        return False
    if current == target:
        return True
    try:
        sysfs.write_charge_behaviour(target)
    except (OSError, ValueError) as exc:
        log(event="write_failed", path=sysfs.charger_path("charge_behaviour"), value=target, error=exc)
        return False
    log(event="write", path=sysfs.charger_path("charge_behaviour"), from_value=current, to_value=target)
    return True


def set_input_current_limit(target_ua: int, last_target_ua: int | None) -> tuple[bool, int | None]:
    current_target = sysfs.read_optional_int(sysfs.charger_path("input_current_limit"))
    if current_target == target_ua and last_target_ua == target_ua:
        return True, last_target_ua
    if current_target == target_ua:
        return True, target_ua

    try:
        sysfs.write_input_current_limit(target_ua)
    except (OSError, ValueError) as exc:
        log(event="write_failed", path=sysfs.charger_path("input_current_limit"), value=target_ua, error=exc)
        return False, last_target_ua

    written_target = sysfs.read_optional_int(sysfs.charger_path("input_current_limit"))
    effective = sysfs.read_optional_int(sysfs.charger_path("current_max"))
    log(
        event="write",
        path=sysfs.charger_path("input_current_limit"),
        from_value=current_target if current_target is not None else "unknown",
        to_value=target_ua,
        target_value=written_target if written_target is not None else "unknown",
        effective_value=effective if effective is not None else "unknown",
        input_limit_mismatch=int(sysfs.input_limit_mismatch(written_target, effective)),
    )
    return True, target_ua


def read_inputs() -> tuple[sysfs.BatteryState, sysfs.ChargerState, PolicyInputs]:
    battery = sysfs.read_battery_state()
    charger = sysfs.read_charger_state()
    inputs = PolicyInputs(
        capacity=battery.capacity,
        temp_decic=battery.temp_decic,
        charge_behaviour=charger.charge_behaviour,
        input_current_limit_target_ua=charger.input_current_limit_target_ua,
        input_current_limit_effective_ua=charger.input_current_limit_effective_ua,
    )
    return battery, charger, inputs


def main() -> None:
    config = PolicyConfig.from_env(log)
    errors = config.validate()
    if errors:
        for reason in errors:
            log(event="invalid_config", reason=reason)
        raise SystemExit(2)
    if not wait_for_sysfs(config):
        raise SystemExit(1)

    log(
        event="start",
        stop_percent=config.stop_percent,
        resume_percent=config.resume_percent,
        charge_input_current_ua=config.charge_input_current_ua,
        hold_input_current_ua=config.hold_input_current_ua,
        hot_stop_decic=config.hot_stop_decic,
        hot_resume_decic=config.hot_resume_decic,
        cold_stop_decic=config.cold_stop_decic,
        cold_resume_decic=config.cold_resume_decic,
        poll_seconds=config.poll_seconds,
    )

    state = PolicyState()
    last_input_target_ua = None

    while True:
        try:
            battery, charger, inputs = read_inputs()
        except (OSError, ValueError) as exc:
            log(event="read_failed", error=exc)
            time.sleep(config.poll_seconds)
            continue

        state, decision = decide(config, state, inputs)

        if decision.target_behaviour == "auto":
            ok, last_input_target_ua = set_input_current_limit(decision.target_input_current_ua, last_input_target_ua)
            if ok:
                set_charge_behaviour(decision.target_behaviour)
        else:
            if set_charge_behaviour(decision.target_behaviour):
                ok, last_input_target_ua = set_input_current_limit(decision.target_input_current_ua, last_input_target_ua)

        try:
            charger = sysfs.read_charger_state()
        except (OSError, ValueError):
            pass

        log(
            event="state",
            capacity=battery.capacity,
            temp_decic=battery.temp_decic,
            online=charger.online,
            battery_status=battery.status,
            current_now_ua=battery.current_now_ua,
            voltage_now_uv=battery.voltage_now_uv,
            charger_status=charger.status,
            charger_current_now_ua=charger.current_now_ua,
            charger_voltage_now_uv=charger.voltage_now_uv,
            behaviour=charger.charge_behaviour,
            target_behaviour=decision.target_behaviour,
            policy_input_current_limit_target_ua=decision.target_input_current_ua,
            input_current_limit_target_ua=charger.input_current_limit_target_ua if charger.input_current_limit_target_ua is not None else "unknown",
            input_current_limit_effective_ua=charger.input_current_limit_effective_ua if charger.input_current_limit_effective_ua is not None else "unknown",
            input_limit_mismatch=int(sysfs.input_limit_mismatch(charger.input_current_limit_target_ua, charger.input_current_limit_effective_ua)),
            temp_block=decision.temp_block or "none",
            soc_block=int(decision.soc_block),
            reason=decision.reason,
        )
        time.sleep(config.poll_seconds)


if __name__ == "__main__":
    main()
