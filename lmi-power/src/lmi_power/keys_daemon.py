import fcntl
import glob
import os
import select
import struct
import time

from .backlight import BacklightController
from . import keymap

EV_KEY = 1
KEY_VOLUMEDOWN = 114
KEY_VOLUMEUP = 115
KEY_POWER = 116
EVENT_FMT = "llHHI"
EVENT_SIZE = struct.calcsize(EVENT_FMT)
EVIOCGRAB = 0x40044590
DEVICE_NAMES = {
    "pm8941_pwrkey": "power",
    "pm8941_resin": "volume-down",
    "gpio-keys": "volume-up",
}
KEY_NAMES = {
    KEY_POWER: "KEY_POWER",
    KEY_VOLUMEDOWN: "KEY_VOLUMEDOWN",
    KEY_VOLUMEUP: "KEY_VOLUMEUP",
}


def log(message: str) -> None:
    print(message, flush=True)


def read_text(path: str, default: str = "") -> str:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return default


def discover_inputs() -> dict[int, tuple[str, str]]:
    found = {}
    for name_path in sorted(glob.glob("/sys/class/input/event*/device/name")):
        name = read_text(name_path)
        if name not in DEVICE_NAMES:
            continue
        event_name = os.path.basename(os.path.dirname(os.path.dirname(name_path)))
        dev_path = os.path.join("/dev/input", event_name)
        if not os.path.exists(dev_path):
            continue
        try:
            fd = os.open(dev_path, os.O_RDONLY | os.O_NONBLOCK)
        except OSError as exc:
            log(f"input_open_failed path={dev_path} name={name} error={str(exc).replace(' ', '_')}")
            continue
        try:
            fcntl.ioctl(fd, EVIOCGRAB, 1)
            grabbed = 1
        except OSError as exc:
            grabbed = 0
            log(f"input_grab_failed path={dev_path} name={name} error={str(exc).replace(' ', '_')}")
        found[fd] = (dev_path, name)
        log(f"input_opened path={dev_path} name={name} role={DEVICE_NAMES[name]} grabbed={grabbed}")
    return found


def close_inputs(fds: dict[int, tuple[str, str]]) -> None:
    for fd in list(fds):
        try:
            os.close(fd)
        except OSError:
            pass
    fds.clear()


def _key_id(code: int) -> str | None:
    if code == KEY_POWER:
        return "power"
    if code == KEY_VOLUMEUP:
        return "volume-up"
    if code == KEY_VOLUMEDOWN:
        return "volume-down"
    return None


def _run_action(controller: BacklightController, key_id: str, action: str) -> None:
    log(f"key_action key={key_id} action={action}")
    if action == "toggle-backlight":
        controller.toggle()
    elif action == "backlight-on":
        controller.set_on()
    elif action == "backlight-off":
        controller.set_off()
    elif action == "brightness-up":
        controller.adjust(1)
    elif action == "brightness-down":
        controller.adjust(-1)
    elif action == "none":
        return


def handle_key(controller: BacklightController, code: int, value: int, name: str) -> None:
    key_name = KEY_NAMES.get(code, f"KEY_{code}")
    log(f"key_event source={name} code={code} name={key_name} value={value}")
    key_id = _key_id(code)
    if key_id is None:
        return
    if code == KEY_POWER and value != 1:
        return
    if code in (KEY_VOLUMEUP, KEY_VOLUMEDOWN) and value not in (1, 2):
        return
    try:
        action = keymap.action_for(key_id)
    except ValueError as exc:
        log(f"keymap_invalid key={key_id} error={str(exc).replace(' ', '_')}")
        action = keymap.DEFAULT_ACTIONS[key_id]
    _run_action(controller, key_id, action)


def main() -> None:
    log("lmi_power_keysd_start")
    controller = BacklightController(log=log)
    status = controller.status()
    if status is not None and status.is_off:
        controller.set_on()
    fds: dict[int, tuple[str, str]] = {}
    while True:
        if not fds:
            fds = discover_inputs()
            if not fds:
                log("input_waiting")
                time.sleep(1)
                continue
        readable, _, _ = select.select(list(fds), [], [], 2)
        for fd in readable:
            dev_path, name = fds[fd]
            while True:
                try:
                    data = os.read(fd, EVENT_SIZE)
                except BlockingIOError:
                    break
                except OSError as exc:
                    log(f"input_read_failed path={dev_path} error={str(exc).replace(' ', '_')}")
                    close_inputs(fds)
                    break
                if len(data) < EVENT_SIZE:
                    break
                _, _, ev_type, code, value = struct.unpack(EVENT_FMT, data)
                if ev_type == EV_KEY:
                    handle_key(controller, code, value, name)


if __name__ == "__main__":
    main()
