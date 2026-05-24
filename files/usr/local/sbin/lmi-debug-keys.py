#!/usr/bin/env python3
import fcntl
import glob
import os
import select
import struct
import time

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
last_brightness = 0
forced_off = False


def log(message):
    print(message, flush=True)


def read_text(path, default=""):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return default


def read_int(path, default=0):
    text = read_text(path)
    try:
        return int(text)
    except ValueError:
        return default


def write_text(path, value):
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(str(value))
        return True
    except OSError as exc:
        log(f"write_failed path={path} value={value} error={exc}")
        return False


def backlight_path():
    for path in sorted(glob.glob("/sys/class/backlight/*")):
        if os.path.exists(os.path.join(path, "brightness")) and os.path.exists(os.path.join(path, "max_brightness")):
            return path
    return None


def is_backlight_off(path):
    bl_power = read_int(os.path.join(path, "bl_power"), 0)
    brightness = read_int(os.path.join(path, "brightness"), 0)
    return forced_off or bl_power != 0 or brightness == 0


def set_backlight_on():
    global forced_off, last_brightness
    path = backlight_path()
    if not path:
        log("backlight_missing action=on")
        return
    max_brightness = max(1, read_int(os.path.join(path, "max_brightness"), 1))
    target = last_brightness if 0 < last_brightness <= max_brightness else max(1, max_brightness // 2)
    write_text(os.path.join(path, "bl_power"), 0)
    write_text(os.path.join(path, "brightness"), target)
    forced_off = False
    last_brightness = target
    log(f"backlight_on path={path} brightness={target}/{max_brightness}")


def set_backlight_off():
    global forced_off, last_brightness
    path = backlight_path()
    if not path:
        log("backlight_missing action=off")
        return
    max_brightness = max(1, read_int(os.path.join(path, "max_brightness"), 1))
    current = read_int(os.path.join(path, "brightness"), 0)
    if current > 0:
        last_brightness = current
    elif last_brightness <= 0:
        last_brightness = max(1, max_brightness // 2)
    write_text(os.path.join(path, "brightness"), 0)
    write_text(os.path.join(path, "bl_power"), 4)
    forced_off = True
    log(f"backlight_off path={path} restore={last_brightness}/{max_brightness}")


def toggle_backlight():
    path = backlight_path()
    if not path:
        log("backlight_missing action=toggle")
        return
    if is_backlight_off(path):
        set_backlight_on()
    else:
        set_backlight_off()


def adjust_brightness(direction):
    global forced_off, last_brightness
    path = backlight_path()
    if not path:
        log("backlight_missing action=adjust")
        return
    max_brightness = max(1, read_int(os.path.join(path, "max_brightness"), 1))
    current = read_int(os.path.join(path, "brightness"), 0)
    was_off = is_backlight_off(path)
    if was_off:
        current = last_brightness if last_brightness > 0 else max(1, max_brightness // 2)
    step = max(1, max_brightness // 20)
    target = max(1, min(max_brightness, current + direction * step))
    if was_off:
        write_text(os.path.join(path, "bl_power"), 0)
    write_text(os.path.join(path, "brightness"), target)
    forced_off = False
    last_brightness = target
    log(f"brightness_change direction={direction} brightness={target}/{max_brightness} step={step}")


def discover_inputs():
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
            log(f"input_open_failed path={dev_path} name={name} error={exc}")
            continue
        try:
            fcntl.ioctl(fd, EVIOCGRAB, 1)
            grabbed = 1
        except OSError as exc:
            grabbed = 0
            log(f"input_grab_failed path={dev_path} name={name} error={exc}")
        found[fd] = (dev_path, name)
        log(f"input_opened path={dev_path} name={name} role={DEVICE_NAMES[name]} grabbed={grabbed}")
    return found


def close_inputs(fds):
    for fd in list(fds):
        try:
            os.close(fd)
        except OSError:
            pass
    fds.clear()


def handle_key(code, value, name):
    key_name = KEY_NAMES.get(code, f"KEY_{code}")
    log(f"key_event source={name} code={code} name={key_name} value={value}")
    if code == KEY_POWER and value == 1:
        toggle_backlight()
    elif code == KEY_VOLUMEUP and value in (1, 2):
        adjust_brightness(1)
    elif code == KEY_VOLUMEDOWN and value in (1, 2):
        adjust_brightness(-1)


def main():
    log("lmi_debug_keys_start")
    fds = {}
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
                    log(f"input_read_failed path={dev_path} error={exc}")
                    close_inputs(fds)
                    break
                if len(data) < EVENT_SIZE:
                    break
                _, _, ev_type, code, value = struct.unpack(EVENT_FMT, data)
                if ev_type == EV_KEY:
                    handle_key(code, value, name)


if __name__ == "__main__":
    main()
