from dataclasses import dataclass
from typing import Optional

from .config import PolicyConfig

AUTO = "auto"
INHIBIT = "inhibit-charge"


@dataclass(frozen=True)
class PolicyInputs:
    capacity: int
    temp_decic: int
    charge_behaviour: str
    input_current_limit_target_ua: Optional[int] = None
    input_current_limit_effective_ua: Optional[int] = None


@dataclass(frozen=True)
class PolicyState:
    temp_block: Optional[str] = None
    soc_block: Optional[bool] = None


@dataclass(frozen=True)
class PolicyDecision:
    target_behaviour: str
    target_input_current_ua: int
    reason: str
    temp_block: Optional[str]
    soc_block: bool
    input_limit_mismatch: bool


def update_temp_block(config: PolicyConfig, temp_decic: int, temp_block: Optional[str]) -> Optional[str]:
    if temp_block == "hot" and temp_decic <= config.hot_resume_decic:
        return None
    if temp_block == "cold" and temp_decic >= config.cold_resume_decic:
        return None
    if temp_decic >= config.hot_stop_decic:
        return "hot"
    if temp_decic <= config.cold_stop_decic:
        return "cold"
    return temp_block


def update_soc_block(config: PolicyConfig, capacity: int, soc_block: Optional[bool], current_behaviour: str) -> bool:
    if capacity >= config.stop_percent:
        return True
    if capacity <= config.resume_percent:
        return False
    if soc_block is None:
        return current_behaviour == INHIBIT
    return soc_block


def decide(config: PolicyConfig, state: PolicyState, inputs: PolicyInputs) -> tuple[PolicyState, PolicyDecision]:
    temp_block = update_temp_block(config, inputs.temp_decic, state.temp_block)
    soc_block = update_soc_block(config, inputs.capacity, state.soc_block, inputs.charge_behaviour)

    if temp_block:
        target_behaviour = INHIBIT
        reason = temp_block
    elif soc_block:
        target_behaviour = INHIBIT
        reason = "soc_high" if inputs.capacity >= config.stop_percent else "soc_hold"
    else:
        target_behaviour = AUTO
        reason = "soc_low" if inputs.capacity <= config.resume_percent else "soc_window"

    target_input = config.charge_input_current_ua if target_behaviour == AUTO else config.hold_input_current_ua
    mismatch = (
        inputs.input_current_limit_target_ua is not None
        and inputs.input_current_limit_effective_ua is not None
        and inputs.input_current_limit_target_ua != inputs.input_current_limit_effective_ua
    )

    next_state = PolicyState(temp_block=temp_block, soc_block=soc_block)
    decision = PolicyDecision(
        target_behaviour=target_behaviour,
        target_input_current_ua=target_input,
        reason=reason,
        temp_block=temp_block,
        soc_block=soc_block,
        input_limit_mismatch=mismatch,
    )
    return next_state, decision
