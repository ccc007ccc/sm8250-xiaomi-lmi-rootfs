import os
from dataclasses import dataclass
from typing import Callable, Iterable, Optional

LogFn = Callable[..., None]


def _env_int(names: Iterable[str], default: int, log: Optional[LogFn] = None) -> int:
    for name in names:
        value = os.environ.get(name)
        if value is None:
            continue
        try:
            return int(value)
        except ValueError:
            if log:
                log(event="invalid_env", name=name, value=value, default=default)
            return default
    return default


@dataclass(frozen=True)
class PolicyConfig:
    stop_percent: int = 70
    resume_percent: int = 65
    charge_input_current_ua: int = 700000
    hold_input_current_ua: int = 1000000
    hot_stop_decic: int = 550
    hot_resume_decic: int = 500
    cold_stop_decic: int = 100
    cold_resume_decic: int = 150
    poll_seconds: int = 30
    wait_seconds: int = 120

    @classmethod
    def from_env(cls, log: Optional[LogFn] = None) -> "PolicyConfig":
        return cls(
            stop_percent=_env_int(("LMI_POWER_STOP_PERCENT", "LMI_BP_STOP_PERCENT"), 70, log),
            resume_percent=_env_int(("LMI_POWER_RESUME_PERCENT", "LMI_BP_RESUME_PERCENT"), 65, log),
            charge_input_current_ua=_env_int(("LMI_POWER_CHARGE_INPUT_CURRENT_UA", "LMI_BP_CHARGE_INPUT_CURRENT_UA"), 700000, log),
            hold_input_current_ua=_env_int(("LMI_POWER_HOLD_INPUT_CURRENT_UA", "LMI_BP_HOLD_INPUT_CURRENT_UA"), 1000000, log),
            hot_stop_decic=_env_int(("LMI_POWER_HOT_STOP_DECIC", "LMI_BP_HOT_STOP_DECIC"), 550, log),
            hot_resume_decic=_env_int(("LMI_POWER_HOT_RESUME_DECIC", "LMI_BP_HOT_RESUME_DECIC"), 500, log),
            cold_stop_decic=_env_int(("LMI_POWER_COLD_STOP_DECIC", "LMI_BP_COLD_STOP_DECIC"), 100, log),
            cold_resume_decic=_env_int(("LMI_POWER_COLD_RESUME_DECIC", "LMI_BP_COLD_RESUME_DECIC"), 150, log),
            poll_seconds=_env_int(("LMI_POWER_POLL_SECONDS", "LMI_BP_POLL_SECONDS"), 30, log),
            wait_seconds=_env_int(("LMI_POWER_WAIT_SECONDS", "LMI_BP_WAIT_SECONDS"), 120, log),
        )

    def validate(self) -> list[str]:
        errors = []
        if self.resume_percent >= self.stop_percent:
            errors.append("resume_percent_must_be_below_stop_percent")
        if self.hot_resume_decic > self.hot_stop_decic:
            errors.append("hot_resume_must_not_exceed_hot_stop")
        if self.cold_resume_decic < self.cold_stop_decic:
            errors.append("cold_resume_must_not_be_below_cold_stop")
        if self.poll_seconds < 5:
            errors.append("poll_seconds_too_low")
        if self.charge_input_current_ua <= 0 or self.hold_input_current_ua <= 0:
            errors.append("input_current_limit_must_be_positive")
        return errors
